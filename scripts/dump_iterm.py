#!/usr/bin/env python3
"""
Dump everything knowable about all open iTerm2 windows into per-window files.
Uses: iTerm2 Python API, macOS Quartz/CGWindow API, AppleScript, and Accessibility.
Creates a new timestamped directory each run.
"""

import site
import sys

# Ensure user site-packages is on the path
sys.path.insert(0, site.getusersitepackages())

import asyncio
import datetime
import json
import os
import subprocess
import textwrap

# ---------------------------------------------------------------------------
# 1. Output directory
# ---------------------------------------------------------------------------
TIMESTAMP = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"iterm_dump_{TIMESTAMP}")
os.makedirs(OUT_DIR, exist_ok=True)


# ---------------------------------------------------------------------------
# 2. Quartz / CGWindow info for iTerm2 windows
# ---------------------------------------------------------------------------
def get_quartz_window_info():
    """Use CGWindowListCopyWindowInfo to get all iTerm2 windows from the window server."""
    try:
        import Quartz
        # kCGWindowListOptionAll = 0, kCGNullWindowID = 0
        window_list = Quartz.CGWindowListCopyWindowInfo(
            Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID
        )
        iterm_windows = []
        for w in window_list:
            owner = w.get("kCGWindowOwnerName", "")
            if "iTerm" in str(owner):
                # Convert CFDict to plain dict
                iterm_windows.append({str(k): _cf_to_python(v) for k, v in w.items()})
        return iterm_windows
    except Exception as e:
        return [{"error": str(e)}]


def _cf_to_python(obj):
    """Best-effort conversion of CoreFoundation types to plain Python."""
    try:
        if isinstance(obj, (int, float, str, bool)):
            return obj
        if hasattr(obj, "items"):
            return {str(k): _cf_to_python(v) for k, v in obj.items()}
        if hasattr(obj, "__iter__"):
            return [_cf_to_python(i) for i in obj]
        return str(obj)
    except Exception:
        return str(obj)


# ---------------------------------------------------------------------------
# 3. AppleScript: everything we can ask System Events + iTerm2 scripting
# ---------------------------------------------------------------------------
def run_applescript(script: str) -> str:
    """Run an AppleScript and return stdout."""
    try:
        r = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=10
        )
        return r.stdout.strip() if r.returncode == 0 else f"ERROR: {r.stderr.strip()}"
    except Exception as e:
        return f"EXCEPTION: {e}"


def get_applescript_window_info():
    """Use AppleScript to get iTerm2 window & tab & session properties."""
    script = textwrap.dedent(r'''
        tell application "iTerm2"
            set output to ""
            set winIdx to 0
            repeat with w in windows
                set winIdx to winIdx + 1
                set output to output & "=== WINDOW " & winIdx & " ===" & linefeed
                try
                    set output to output & "  name: " & (name of w) & linefeed
                end try
                try
                    set output to output & "  id: " & (id of w) & linefeed
                end try
                try
                    set output to output & "  bounds: " & (bounds of w as text) & linefeed
                end try
                try
                    set output to output & "  frame: " & (frame of w as text) & linefeed
                end try
                try
                    set output to output & "  position: " & (position of w as text) & linefeed
                end try
                try
                    set output to output & "  size: " & (size of w as text) & linefeed
                end try
                try
                    set output to output & "  visible: " & (visible of w) & linefeed
                end try
                try
                    set output to output & "  miniaturized: " & (miniaturized of w) & linefeed
                end try
                try
                    set output to output & "  frontmost: " & (frontmost of w) & linefeed
                end try
                try
                    set output to output & "  index: " & (index of w) & linefeed
                end try
                try
                    set output to output & "  zoomed: " & (zoomed of w) & linefeed
                end try
                try
                    set output to output & "  isHotkeyWindow: " & (is hotkey window of w) & linefeed
                end try
                try
                    set tabIdx to 0
                    repeat with t in tabs of w
                        set tabIdx to tabIdx + 1
                        set output to output & "  --- TAB " & tabIdx & " ---" & linefeed
                        try
                            set output to output & "    index: " & (index of t) & linefeed
                        end try
                        try
                            set output to output & "    currentSession: " & (id of current session of t) & linefeed
                        end try
                        set sessIdx to 0
                        repeat with s in sessions of t
                            set sessIdx to sessIdx + 1
                            set output to output & "    +++ SESSION " & sessIdx & " +++" & linefeed
                            try
                                set output to output & "      id: " & (id of s) & linefeed
                            end try
                            try
                                set output to output & "      name: " & (name of s) & linefeed
                            end try
                            try
                                set output to output & "      tty: " & (tty of s) & linefeed
                            end try
                            try
                                set output to output & "      columns: " & (columns of s) & linefeed
                            end try
                            try
                                set output to output & "      rows: " & (rows of s) & linefeed
                            end try
                            try
                                set output to output & "      profileName: " & (profile name of s) & linefeed
                            end try
                            try
                                set output to output & "      colorPreset: " & (color preset of s) & linefeed
                            end try
                            try
                                set output to output & "      backgroundColor: " & (background color of s as text) & linefeed
                            end try
                            try
                                set output to output & "      foregroundColor: " & (foreground color of s as text) & linefeed
                            end try
                            try
                                set output to output & "      transparency: " & (transparency of s) & linefeed
                            end try
                            try
                                set output to output & "      uniqueId: " & (unique id of s) & linefeed
                            end try
                            try
                                set output to output & "      isProcessing: " & (is processing of s) & linefeed
                            end try
                            try
                                set output to output & "      isAtShellPrompt: " & (is at shell prompt of s) & linefeed
                            end try
                            try
                                set output to output & "      commandRunning: " & (is processing of s) & linefeed
                            end try
                        end repeat
                    end repeat
                end try
            end repeat
            return output
        end tell
    ''')
    return run_applescript(script)


def get_system_events_info():
    """Use System Events to get accessibility-level UI info about iTerm2 windows."""
    script = textwrap.dedent(r'''
        tell application "System Events"
            tell process "iTerm2"
                set output to "frontmost: " & (frontmost) & linefeed
                set output to output & "windowCount: " & (count of windows) & linefeed
                set winIdx to 0
                repeat with w in windows
                    set winIdx to winIdx + 1
                    set output to output & "=== SysEvents WINDOW " & winIdx & " ===" & linefeed
                    try
                        set output to output & "  title: " & (title of w) & linefeed
                    end try
                    try
                        set output to output & "  name: " & (name of w) & linefeed
                    end try
                    try
                        set output to output & "  description: " & (description of w) & linefeed
                    end try
                    try
                        set output to output & "  role: " & (role of w) & linefeed
                    end try
                    try
                        set output to output & "  subrole: " & (subrole of w) & linefeed
                    end try
                    try
                        set output to output & "  position: " & (position of w as text) & linefeed
                    end try
                    try
                        set output to output & "  size: " & (size of w as text) & linefeed
                    end try
                    try
                        set output to output & "  focused: " & (focused of w) & linefeed
                    end try
                    try
                        set output to output & "  enabled: " & (enabled of w) & linefeed
                    end try
                    try
                        set output to output & "  minimized: " & (value of attribute "AXMinimized" of w) & linefeed
                    end try
                    try
                        set output to output & "  fullScreen: " & (value of attribute "AXFullScreen" of w) & linefeed
                    end try
                    try
                        set output to output & "  closeButton: " & (exists of (first button whose subrole is "AXCloseButton") of w) & linefeed
                    end try
                    try
                        set output to output & "  attributes: " & (name of attributes of w as text) & linefeed
                    end try
                    -- Enumerate toolbar items, tab groups, etc
                    try
                        set output to output & "  uiElementCount: " & (count of UI elements of w) & linefeed
                        set elIdx to 0
                        repeat with el in UI elements of w
                            set elIdx to elIdx + 1
                            try
                                set output to output & "    UIElement" & elIdx & ": role=" & (role of el) & " subrole=" & (subrole of el) & " desc=" & (description of el) & linefeed
                            end try
                        end repeat
                    end try
                end repeat
                return output
            end tell
        end tell
    ''')
    return run_applescript(script)


# ---------------------------------------------------------------------------
# 4. iTerm2 Python API (async, connects via iTerm's built-in websocket)
# ---------------------------------------------------------------------------
async def get_iterm2_api_info():
    """Use the iterm2 Python API to dump everything about windows/tabs/sessions."""
    try:
        import iterm2
    except ImportError:
        return {"error": "iterm2 package not installed"}

    results = {}
    try:
        connection = await iterm2.Connection.async_create()
        app = await iterm2.async_get_app(connection)

        results["app_info"] = {
            "terminal_window_count": len(app.terminal_windows),
            "current_terminal_window_id": app.current_terminal_window.window_id if app.current_terminal_window else None,
            "buried_sessions": [s.session_id for s in app.buried_sessions] if app.buried_sessions else [],
        }

        for wi, window in enumerate(app.terminal_windows):
            wkey = f"window_{wi}"
            winfo = {}
            winfo["window_id"] = window.window_id
            try:
                frame = await window.async_get_frame()
                winfo["frame"] = {"x": frame.origin.x, "y": frame.origin.y,
                                  "width": frame.size.width, "height": frame.size.height}
            except Exception as e:
                winfo["frame_error"] = str(e)
            try:
                winfo["fullscreen"] = await window.async_get_fullscreen()
            except Exception:
                pass
            winfo["tab_count"] = len(window.tabs)
            winfo["current_tab_id"] = window.current_tab.tab_id if window.current_tab else None

            tabs_info = {}
            for ti, tab in enumerate(window.tabs):
                tkey = f"tab_{ti}"
                tinfo = {}
                tinfo["tab_id"] = tab.tab_id
                try:
                    tinfo["tmux_window_id"] = tab.tmux_window_id
                except Exception:
                    pass
                tinfo["session_count"] = len(tab.sessions)
                tinfo["current_session_id"] = tab.current_session.session_id if tab.current_session else None

                sessions_info = {}
                for si, session in enumerate(tab.sessions):
                    skey = f"session_{si}"
                    sinfo = {}
                    sinfo["session_id"] = session.session_id
                    sinfo["name"] = session.name
                    try:
                        sinfo["auto_name"] = session.auto_name
                    except Exception:
                        pass
                    try:
                        sinfo["preferred_size"] = str(session.preferred_size)
                    except Exception:
                        pass
                    try:
                        profile = await session.async_get_profile()
                        sinfo["profile"] = {
                            "name": profile.name if hasattr(profile, 'name') else None,
                        }
                        # Dump all gettable profile properties
                        profile_props = {}
                        for attr in dir(profile):
                            if attr.startswith("_") or attr.startswith("async_") or attr.startswith("set_"):
                                continue
                            try:
                                val = getattr(profile, attr)
                                if callable(val):
                                    continue
                                profile_props[attr] = _safe_serialize(val)
                            except Exception:
                                pass
                        sinfo["profile_properties"] = profile_props
                    except Exception as e:
                        sinfo["profile_error"] = str(e)

                    try:
                        var_names = [
                            "jobName", "jobPid", "effectiveRootPid", "path",
                            "hostname", "username", "shell", "terminalIconName",
                            "terminalWindowName", "commandLine", "presentationName",
                            "localhostName", "sshIntegrationLevel",
                        ]
                        variables = {}
                        for vn in var_names:
                            try:
                                v = await session.async_get_variable(vn)
                                variables[vn] = v
                            except Exception:
                                pass
                        # Also try to get all variables
                        try:
                            all_vars = await session.async_get_variable("*")
                            if isinstance(all_vars, dict):
                                variables["_all"] = {k: _safe_serialize(v) for k, v in all_vars.items()}
                        except Exception:
                            pass
                        sinfo["variables"] = variables
                    except Exception as e:
                        sinfo["variables_error"] = str(e)

                    # Screen contents: last N lines
                    try:
                        contents = await session.async_get_screen_contents()
                        lines = []
                        for line_idx in range(contents.number_of_lines):
                            line = contents.line(line_idx)
                            lines.append(_clean_text(line.string))
                        sinfo["screen_contents"] = {
                            "number_of_lines": contents.number_of_lines,
                            "cursor_coord": {
                                "x": contents.cursor_coord.x,
                                "y": contents.cursor_coord.y
                            } if contents.cursor_coord else None,
                            "number_of_lines_above_screen": contents.number_of_lines_above_screen,
                            "lines": lines,
                        }
                    except Exception as e:
                        sinfo["screen_contents_error"] = str(e)

                    sessions_info[skey] = sinfo
                tinfo["sessions"] = sessions_info
                tabs_info[tkey] = tinfo
            winfo["tabs"] = tabs_info
            results[wkey] = winfo

    except Exception as e:
        results["connection_error"] = str(e)

    return results


def _clean_text(s):
    """Strip null bytes, ANSI escapes, and other control chars to produce readable plain text."""
    import re
    if not isinstance(s, str):
        return s
    # Replace null bytes with spaces
    s = s.replace("\u0000", " ")
    # Strip ANSI escape sequences (CSI, OSC, etc.)
    s = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", s)   # CSI sequences
    s = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", s)  # OSC sequences
    s = re.sub(r"\x1b[^[\]()][^\x1b]*", "", s)     # other ESC sequences
    # Remove remaining control chars except newline/tab
    s = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", s)
    return s


def _safe_serialize(obj):
    """Make obj JSON-serializable."""
    try:
        json.dumps(obj)
        return obj
    except (TypeError, ValueError):
        if hasattr(obj, "__dict__"):
            return {k: _safe_serialize(v) for k, v in obj.__dict__.items() if not k.startswith("_")}
        return str(obj)


# ---------------------------------------------------------------------------
# 5. Extra: lsof for iTerm's open FDs, process tree, env
# ---------------------------------------------------------------------------
def get_process_info():
    """Grab iTerm2 process-level info via ps, lsof, etc."""
    info = {}
    try:
        r = subprocess.run(["pgrep", "-x", "iTerm2"], capture_output=True, text=True, timeout=5)
        pids = r.stdout.strip().split("\n") if r.stdout.strip() else []
        info["pids"] = pids
    except Exception as e:
        info["pids_error"] = str(e)

    for pid in info.get("pids", []):
        try:
            r = subprocess.run(["ps", "-p", pid, "-o", "pid,ppid,pgid,user,stat,%cpu,%mem,etime,command"],
                               capture_output=True, text=True, timeout=5)
            info[f"ps_{pid}"] = r.stdout.strip()
        except Exception:
            pass
        try:
            r = subprocess.run(["lsof", "-p", pid, "-Fn"], capture_output=True, text=True, timeout=10)
            info[f"lsof_{pid}"] = r.stdout[:5000]  # cap size
        except Exception:
            pass

    return info


# ---------------------------------------------------------------------------
# 6. Extra: window server info via screencapture -l for window IDs
# ---------------------------------------------------------------------------
def get_window_list_via_cli():
    """Grab window IDs from CGWindowListCopyWindowInfo via Python — already done in quartz section."""
    # Fallback: use `osascript` to list windows
    script = 'tell application "iTerm2" to return id of every window'
    return run_applescript(script)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
async def main():
    print(f"Output directory: {OUT_DIR}")

    # Gather non-async sources in parallel-ish fashion
    print("Gathering Quartz CGWindow info...")
    quartz_info = get_quartz_window_info()

    print("Gathering AppleScript iTerm2 info...")
    applescript_info = get_applescript_window_info()

    print("Gathering System Events accessibility info...")
    sysevents_info = get_system_events_info()

    print("Gathering process info...")
    process_info = get_process_info()

    print("Gathering iTerm2 window IDs via AppleScript...")
    window_ids_raw = get_window_list_via_cli()

    # iTerm2 Python API
    print("Connecting to iTerm2 Python API...")
    iterm2_info = await get_iterm2_api_info()

    # -----------------------------------------------------------------------
    # Now write one file per window, combining all sources
    # -----------------------------------------------------------------------

    # Determine window count from the richest source
    # Parse AppleScript output to split by window
    applescript_windows = []
    if applescript_info and "=== WINDOW" in applescript_info:
        parts = applescript_info.split("=== WINDOW ")
        for part in parts[1:]:
            applescript_windows.append("=== WINDOW " + part.strip())
    else:
        applescript_windows = [applescript_info or "(no data)"]

    sysevents_windows = []
    if sysevents_info and "=== SysEvents WINDOW" in sysevents_info:
        # Split header from per-window
        header_and_rest = sysevents_info.split("=== SysEvents WINDOW ")
        se_header = header_and_rest[0].strip()
        for part in header_and_rest[1:]:
            sysevents_windows.append("=== SysEvents WINDOW " + part.strip())
    else:
        se_header = sysevents_info or "(no data)"
        sysevents_windows = []

    # How many windows?
    iterm2_window_keys = sorted([k for k in iterm2_info if k.startswith("window_")])
    n_windows = max(len(applescript_windows), len(sysevents_windows),
                    len(iterm2_window_keys), len(quartz_info))

    if n_windows == 0:
        # Write a single file with whatever we got
        n_windows = 1

    for i in range(n_windows):
        filename = os.path.join(OUT_DIR, f"window_{i+1:02d}.txt")
        chunks = []

        chunks.append(f"{'='*72}")
        chunks.append(f" iTerm2 Window {i+1} -- Full Dump @ {TIMESTAMP}")
        chunks.append(f"{'='*72}\n")

        # Quartz CGWindow
        chunks.append(f"{'─'*72}")
        chunks.append("QUARTZ / CGWindowListCopyWindowInfo")
        chunks.append(f"{'─'*72}")
        if i < len(quartz_info):
            chunks.append(json.dumps(quartz_info[i], indent=2, default=str))
        else:
            chunks.append("(no Quartz data for this window index)")
        chunks.append("")

        # AppleScript iTerm2
        chunks.append(f"{'─'*72}")
        chunks.append("APPLESCRIPT -- iTerm2 SCRIPTING DICTIONARY")
        chunks.append(f"{'─'*72}")
        if i < len(applescript_windows):
            chunks.append(applescript_windows[i])
        else:
            chunks.append("(no AppleScript data for this window index)")
        chunks.append("")

        # System Events / Accessibility
        chunks.append(f"{'─'*72}")
        chunks.append("SYSTEM EVENTS / ACCESSIBILITY")
        chunks.append(f"{'─'*72}")
        if i == 0:
            chunks.append(se_header)
        if i < len(sysevents_windows):
            chunks.append(sysevents_windows[i])
        else:
            chunks.append("(no System Events data for this window index)")
        chunks.append("")

        # iTerm2 Python API
        chunks.append(f"{'─'*72}")
        chunks.append("iTerm2 PYTHON API")
        chunks.append(f"{'─'*72}")
        if i < len(iterm2_window_keys):
            wdata = iterm2_info[iterm2_window_keys[i]]
            chunks.append(json.dumps(wdata, indent=2, default=str))
        elif i == 0 and "connection_error" in iterm2_info:
            chunks.append(f"Connection error: {iterm2_info['connection_error']}")
        else:
            chunks.append("(no Python API data for this window index)")
        if "app_info" in iterm2_info and i == 0:
            chunks.append("\nApp-level info:")
            chunks.append(json.dumps(iterm2_info["app_info"], indent=2, default=str))
        chunks.append("")

        # Process info (same for all windows, write in window 1)
        if i == 0:
            chunks.append(f"{'─'*72}")
            chunks.append("PROCESS INFO (iTerm2 PIDs, ps, lsof)")
            chunks.append(f"{'─'*72}")
            chunks.append(json.dumps(process_info, indent=2, default=str))
            chunks.append("")

        # Window IDs
        if i == 0:
            chunks.append(f"{'─'*72}")
            chunks.append("APPLESCRIPT WINDOW IDS")
            chunks.append(f"{'─'*72}")
            chunks.append(window_ids_raw)

        # Clean everything and write
        full_text = "\n".join(chunks)
        full_text = _clean_text(full_text)
        with open(filename, "w") as f:
            f.write(full_text)

        print(f"  Wrote {filename}")

    print(f"\nDone! {n_windows} window file(s) in {OUT_DIR}")


if __name__ == "__main__":
    asyncio.run(main())
