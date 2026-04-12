---
description: End-to-end visual smoke test of VibeGrid — launch, exercise UI, verify iTerm activity + mux-kill pipeline
---

You are running an end-to-end visual test of VibeGrid. Use computer-use tools
(screenshot, click, key) to exercise each feature and verify it works. This
skill is the primary regression harness for the iTerm activity pipeline and
the close-window / mux-kill flow — the two areas where most recent bugs have
lived and that unit tests can't fully cover.

## Ground rules

**Always state the build you're testing** — at the very top of your report, log
`git rev-parse --short HEAD` and the current branch. A visual test report that
doesn't pin a commit is unreviewable.

**Screenshot before and after every action.** Every PASS/FAIL needs visual
evidence, with the commit in frame if possible.

**If you can't verify something visually, say so explicitly** — don't claim
success for anything you couldn't observe. A clear "UNVERIFIED — reason" beats
a false PASS.

**Fail fast on prereq problems.** If setup fails (wrong build, no access, no
iTerm windows to test against) — stop, report the blocker, don't fabricate
test results on a broken setup.

**Teardown** at the end: leave VibeGrid running, close any temporary iTerm
windows/tmux sessions the test spawned, and restore any settings you toggled.

## Prerequisites

Run these checks **in order**. If any fails, stop and report the failure:

```bash
# 1. Must be running from the .app bundle (menu bar icon visible to computer-use)
pgrep -f "VibeGrid.app/Contents/MacOS/VibeGrid"

# 2. Git state pinned for the report
git rev-parse --short HEAD
git symbolic-ref --short HEAD

# 3. Debug log freshness — should have recent entries
ls -la ~/Library/Application\ Support/VibeGrid/logs/window-list-debug.log
tail -5 ~/Library/Application\ Support/VibeGrid/logs/window-list-debug.log

# 4. mux binary discoverable (needed for close-window mux-kill tests)
for p in ~/.local/bin/mux /usr/local/bin/mux /opt/homebrew/bin/mux; do
  [ -x "$p" ] && echo "found: $p" && break
done

# 5. vibed state file recency (needed for activity overlay tests)
stat -f '%m %N' ~/.local/state/vibed/state.json 2>/dev/null || echo "vibed not running"
```

If `pgrep` is empty or shows a raw `swift run` binary, rebuild:
```bash
./scripts/run_dev.sh
```

## Setup: Request Computer-Use Access

Before any screenshot or click, call `request_access` with **all apps** and
`systemKeyCombos: true`:

```
apps: ["iTerm2", "Cursor", "Firefox", "VibeGrid"]
systemKeyCombos: true
reason: "Running visual test of VibeGrid"
```

**Tier limitations** (as of 2026-04-12):
- **VibeGrid**: full access (click, type, drag)
- **iTerm2, Cursor, Terminal**: click-only (no typing/right-click/drag)
- **Firefox / Chrome / Safari**: read-only (visible in screenshots, no interaction)
- For shell commands, use the Bash tool directly, NOT iTerm2

Without requesting access to iTerm2, clicks near iTerm windows will be
rejected even when targeting VibeGrid.

## Test Plan

Execute each section. For each test, screenshot before + after. Report
PASS/FAIL/UNVERIFIED with a short reason.

---

### Section A — Control Center UI surface

#### A1. Control Center opens
- Click the VibeGrid menu bar icon (or run `osascript -e 'tell application "VibeGrid" to activate'`).
- Screenshot — verify 3-column layout (shortcut list | editor | preview).
- Expected: no empty panels, no error banners.

#### A2. Shortcut list
- Screenshot the left panel.
- Verify: shortcuts are listed with names and enable toggles.
- Click a shortcut — screenshot — verify the center panel updates with its details.

#### A3. Grid editor
- With a grid-mode shortcut selected, screenshot the right panel.
- Click grid cells to modify the placement — screenshot — verify the selection updated and persists.
- Revert your changes at the end of this test.

#### A4. Settings modal
- Click the Settings (gear) button.
- Screenshot — verify the modal opens with theme, grid defaults, gap, launch-at-login, and iTerm activity sections.
- Close the modal (Escape).

#### A5. Hotkey recording
- Select a shortcut, click its hotkey field.
- Screenshot — verify recording state (highlight/pulse).
- Press Escape to cancel — verify the field returns to its prior value.

#### A6. Theme toggle
- Open settings, toggle dark ↔ light → screenshot both states.
- Verify: background, button surfaces, text contrast all repaint.
- Return to original theme.

---

### Section B — Window List (Move Everything)

#### B1. Window list populated
- Click "Window List" in the top bar.
- Screenshot — verify: windows are listed with app icons, titles, and status indicators.
- Expected: iTerm windows are grouped/ordered with claude-code first, then codex, then others.

#### B2. Hover highlights and name override
- Hover over a window entry → screenshot.
- Click the name override control on an iTerm window → screenshot.
- Set a test name, press Enter — verify it appears on the entry. Revert.

#### B3. Repository grouping
- In the window list, verify iTerm windows are grouped by repository (e.g. `vibegrid`, `torch-infinity ⑂` for worktrees).
- Screenshot the grouped view.

---

### Section C — iTerm activity indicators (the critical regression surface)

These tests cover the code path where nearly every recent bug has lived.

**Setup:** Make sure at least one iTerm window is running a Claude Code or Codex
session. If none are active, start one in a spare iTerm window:
```bash
cd ~/github/vibegrid && claude --help >/dev/null   # just launches claude briefly
```
If you can't start one, mark Section C as UNVERIFIED and skip it — don't
fabricate results.

#### C1. Active-state tint visible
- Screenshot the iTerm window running an active Claude/Codex session.
- Verify: background has a **green** tint (active color, default `#2f8f4e`).
- Verify: tab has a green tab color.

#### C2. Idle-state tint visible
- Wait ~10 seconds after Claude finishes (past the hold period).
- Screenshot the same iTerm window.
- Verify: background has a **red** tint (idle color, default `#ba4d4d`).

#### C3. Hold period prevents flicker
- Actively work in a Claude Code session so it's in "active" state.
- At a natural pause (Claude finishes, waits for you), watch the tint for ~5 seconds.
- Screenshot every 2 seconds → verify the tint stays green for at least `holdSeconds` (default 7s) without flipping to red.
- This is the regression test for the "flicker during typing / idle blips" bug. If it flickers before 7s, that's a FAIL.

#### C4. Typing doesn't flip the indicator
- Check `~/Library/Application Support/VibeGrid/config.yaml` for
  `moveEverythingITermActivityBackgroundTintPersistent`.
- With persistent = true: start typing in the Claude prompt → screenshot →
  verify the tint stays whatever it was (green or red, not flickering).
- This tests that recent input doesn't destabilize the cache.

#### C5. Window list activity badges
- Open the Window List panel.
- Screenshot — verify active claude-code/codex windows show an active badge/color
  and idle ones show an idle state.
- Cross-check with Section C1/C2 — the window list and the iTerm tint should agree.

#### C6. Repository groups reflect vibed state
- If vibed has remote sessions (e.g. `neb-4-mcp`), verify they show in the Window
  List grouped under their repo (from `pane_path`).
- Screenshot the remote group entries.

#### C7. Vibed state sanity check (non-visual diagnostic)
- Run:
  ```bash
  jq '.sessions | to_entries | map({id: .key, status: .value.status, tool: .value.tool, window_id: .value.window_id, name: .value.name})' ~/.local/state/vibed/state.json 2>/dev/null | head -80
  ```
- Check for duplicate `window_id` values across sessions — if present, the vibed
  overlay dedup (commit `0836e43`) is load-bearing and should be kept green.

---

### Section D — Close window + mux kill (the other critical path)

**Setup:** Confirm mux is available. If it isn't, mark Section D as UNVERIFIED.

```bash
MUX=$(for p in ~/.local/bin/mux /usr/local/bin/mux /opt/homebrew/bin/mux; do [ -x "$p" ] && echo "$p" && break; done)
echo "mux=$MUX"
[ -n "$MUX" ] && "$MUX" list 2>&1 | head -20
```

#### D1. Move-Everything close kills the mux session
- `"$MUX" list` — note current sessions (call this the **BEFORE** list).
- Open an iTerm window attached to a mux session you can safely kill (ideally a
  scratch one you just created — do NOT target production work).
- Activate Move-Everything mode. Hover the iTerm window. Press the close hotkey.
- Screenshot — verify the iTerm window disappears.
- `"$MUX" list` — the target session should be **GONE** from the list.
- Cross-check with `~/Library/Application Support/VibeGrid/logs/window-list-debug.log`:
  ```bash
  tail -50 ~/Library/Application\ Support/VibeGrid/logs/window-list-debug.log | grep -iE "close override|mux kill"
  ```
- Expected log line: `close override — dispatching mux kill for key=... session=...` followed by `mux kill succeeded`.
- **FAIL conditions:** iTerm window closes but mux session still in list; log says "mux binary not found"; log says "no session in cache".

#### D2. Close outside Move-Everything mode (known edge)
- Focus an iTerm window without entering Move-Everything mode.
- Press the close hotkey.
- Screenshot before/after + `"$MUX" list` before/after.
- Expected: iTerm window closes; mux session **may or may not** be killed — this
  path has limited key reconstruction and is a known edge case. Mark PASS if the
  window closes cleanly regardless of mux state; note in results whether mux was
  killed.

#### D3. Close with indicators disabled doesn't leave stale tint
- In Settings, disable both `moveEverythingITermActivityBackgroundTintEnabled`
  and `moveEverythingITermActivityTabColorEnabled`.
- Screenshot the iTerm windows — verify all tints were restored to original colors.
- Check `~/Library/Application Support/VibeGrid/tinted-windows.json`:
  ```bash
  cat ~/Library/Application\ Support/VibeGrid/tinted-windows.json 2>/dev/null || echo "file absent (fine)"
  ```
- Re-enable the settings — verify tints return cleanly.

---

### Section E — Failure-mode checks

#### E1. Log freshness
- ```bash
  tail -20 ~/Library/Application\ Support/VibeGrid/logs/window-list-debug.log
  ```
- Expected: entries from within the last ~30 seconds (poll cycle is ~1s).
- If log is stale, VibeGrid's activity poll is stuck — FAIL.

#### E2. CPU sanity
- ```bash
  ps -o pid,%cpu,%mem,comm -p $(pgrep -f "VibeGrid.app" | head -1)
  ```
- Expected: <5% CPU at rest.
- If >20%, note it and attach a `sample` for investigation.

#### E3. No NSLog spam about missing binaries / caches
- ```bash
  log show --predicate 'process == "VibeGrid"' --info --last 5m 2>&1 | grep -iE "binary not found|no session in cache|parse failed|timed out" | head -20
  ```
- Expected: clean output (or only rare timeouts under load).

---

## Report format

Paste the output of the prereq commands at the top, then the results table, then
any screenshots attached as evidence. Example:

```
# VibeGrid visual test — 2026-04-12T17:45:02+02:00
build: 0836e43 (main)
mux binary: ~/.local/bin/mux
vibed state age: 3s
```

| Section | Test | Result | Notes |
|---------|------|--------|-------|
| A1 | Control Center opens | PASS | |
| A2 | Shortcut list | PASS | |
| ... | ... | ... | ... |
| C3 | Hold period prevents flicker | PASS | No flicker during 8s observation window |
| D1 | Close kills mux session | FAIL | iTerm closed but `local-42` still in mux list; log: "no session in cache" |

**For each FAIL or UNVERIFIED, include:**
- Screenshot evidence (attachment paths)
- Relevant log lines (from `window-list-debug.log` or `log show`)
- One-line suspected root cause

Do not summarize with a "mostly working!" handwave — list every test that
didn't cleanly PASS, even if the overall build seems healthy.

$ARGUMENTS
