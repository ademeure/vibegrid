from __future__ import annotations

import re
import subprocess
import time

import iterm2

from .models import PollEntry


TMUX_SESSION_PATTERN = re.compile(r"tmux\s+(?:attach|a|new|new-session)\s+.*?-t\s+\W*(\w[\w-]*)")

# Cache tmux pane commands to avoid shelling out every poll cycle.
_tmux_pane_command_cache: dict[str, tuple[str, float]] = {}
_TMUX_PANE_COMMAND_CACHE_TTL = 5.0


def _query_tmux_pane_info(session_name: str) -> tuple[str, str]:
    """Query the foreground command and cwd of a tmux session's active pane."""
    now = time.monotonic()
    cached = _tmux_pane_command_cache.get(session_name)
    if cached and now - cached[1] < _TMUX_PANE_COMMAND_CACHE_TTL:
        return cached[0]
    try:
        result = subprocess.run(
            ["tmux", "list-panes", "-t", session_name, "-F", "#{pane_current_command}\t#{pane_current_path}"],
            capture_output=True, text=True, timeout=2,
        )
        if result.returncode == 0:
            parts = result.stdout.strip().split("\n")[0].split("\t", 1)
            cmd = parts[0].strip()
            path = parts[1].strip() if len(parts) > 1 else ""
        else:
            cmd, path = "", ""
    except Exception:
        cmd, path = "", ""
    info = (cmd, path)
    _tmux_pane_command_cache[session_name] = (info, now)
    return info


async def _capture_screen_lines(
    session,
    connection,
    max_polled_non_empty_lines: int,
) -> tuple[str, list[str]]:
    """Capture visible screen lines from the bottom. Returns (last_line, non_empty_lines)."""
    last_line = ""
    non_empty_lines: list[str] = []
    try:
        async with iterm2.Transaction(connection):
            line_info = await session.async_get_line_info()
            visible_height = max(1, int(line_info.mutable_area_height))
            requested_lines = min(visible_height, max_polled_non_empty_lines)
            # Read from the bottom of the mutable area (where new output appears),
            # NOT from first_visible_line_number. This prevents user scrolling
            # from triggering false activity detection.
            mutable_area_start = int(line_info.scrollback_buffer_height)
            first_line = mutable_area_start + max(0, visible_height - requested_lines)
            lines = await session.async_get_contents(first_line, requested_lines)

        for line in reversed(lines):
            candidate = line.string.strip()
            if candidate:
                if not last_line:
                    last_line = candidate[:240]
                non_empty_lines.append(candidate[:240])
    except Exception:
        pass
    return last_line, non_empty_lines


async def _fetch_metadata(session) -> dict[str, str]:
    """Fetch session metadata (badge, commandLine, presentationName). Slow — cache this."""
    badge_text = ""
    command_line = ""
    presentation_name = ""
    session_name = ""

    try:
        badge = await session.async_get_variable("badge")
        if isinstance(badge, str) and badge.strip():
            badge_text = badge.strip()
    except Exception:
        pass

    tmux_pane_command = ""
    tmux_pane_path = ""
    try:
        command_line = str(await session.async_get_variable("commandLine") or "").strip()
        presentation_name = str(await session.async_get_variable("presentationName") or "").strip()
        match = TMUX_SESSION_PATTERN.search(command_line)
        if match:
            session_name = match.group(1)
            tmux_pane_command, tmux_pane_path = _query_tmux_pane_info(session_name)
        elif presentation_name and presentation_name not in {"-zsh", "zsh", "bash", "-bash", "fish", "login"}:
            session_name = presentation_name
    except Exception:
        pass

    return {
        "badge_text": badge_text,
        "command_line": command_line,
        "tmux_pane_command": tmux_pane_command,
        "tmux_pane_path": tmux_pane_path,
        "presentation_name": presentation_name,
        "session_name": session_name,
    }


class CachedWindowMetadata:
    """Per-window metadata cache with TTL."""

    def __init__(self, ttl: float = 1.0):
        self.ttl = ttl
        self._cache: dict[str, tuple[float, dict[str, str]]] = {}

    def get(self, window_id: str) -> dict[str, str] | None:
        entry = self._cache.get(window_id)
        if entry is None:
            return None
        fetched_at, metadata = entry
        if time.monotonic() - fetched_at > self.ttl:
            return None
        return metadata

    def put(self, window_id: str, metadata: dict[str, str]) -> None:
        self._cache[window_id] = (time.monotonic(), metadata)

    def prune(self, active_ids: set[str]) -> None:
        """Remove entries for windows that no longer exist."""
        stale = [k for k in self._cache if k not in active_ids]
        for k in stale:
            del self._cache[k]


async def collect_window_snapshots(
    connection,
    max_polled_non_empty_lines: int,
    metadata_cache: CachedWindowMetadata | None = None,
    original_bg_by_profile_guid: dict | None = None,
) -> list[PollEntry]:
    app = await iterm2.async_get_app(connection)
    entries: list[PollEntry] = []
    active_ids: set[str] = set()

    for window in app.windows:
        window_id = str(window.window_id)
        active_ids.add(window_id)

        try:
            current_session = window.current_tab.current_session
        except Exception:
            current_session = None

        # Always fetch screen lines (this is what the detector needs)
        last_line = ""
        non_empty_lines: list[str] = []
        if current_session is not None:
            last_line, non_empty_lines = await _capture_screen_lines(
                current_session, connection, max_polled_non_empty_lines
            )

        # Metadata: use cache if available, fetch only when stale
        metadata: dict[str, str] | None = None
        if metadata_cache is not None:
            metadata = metadata_cache.get(window_id)
        if metadata is None and current_session is not None:
            metadata = await _fetch_metadata(current_session)
            if metadata_cache is not None:
                metadata_cache.put(window_id, metadata)
        if metadata is None:
            metadata = {"badge_text": "", "command_line": "", "tmux_pane_command": "", "tmux_pane_path": "", "presentation_name": "", "session_name": ""}

        # Background color is populated by the worker from the profile list cache
        bg_r, bg_g, bg_b = 0, 0, 0
        bg_light_r, bg_light_g, bg_light_b = 0, 0, 0
        use_separate_colors = False
        if original_bg_by_profile_guid is not None:
            try:
                if current_session is not None:
                    profile = await current_session.async_get_profile()
                    guid = profile.guid
                    # Try exact GUID, then original_guid (for tmux/dynamic profiles),
                    # then fall back to any cached profile
                    info = None
                    if guid and guid in original_bg_by_profile_guid:
                        info = original_bg_by_profile_guid[guid]
                    elif hasattr(profile, 'original_guid') and profile.original_guid:
                        info = original_bg_by_profile_guid.get(profile.original_guid)
                    if info is None and original_bg_by_profile_guid:
                        info = next(iter(original_bg_by_profile_guid.values()))
                    if info is not None:
                        bg_r, bg_g, bg_b = info.dark
                        bg_light_r, bg_light_g, bg_light_b = info.light
                        use_separate_colors = info.use_separate
            except Exception:
                pass

        frame = window.frame
        entries.append(
            PollEntry(
                window_id=window_id,
                tty_active=False,
                x=float(frame.origin.x),
                y=float(frame.origin.y),
                width=float(frame.size.width),
                height=float(frame.size.height),
                badge_text=metadata["badge_text"],
                session_name=metadata["session_name"],
                presentation_name=metadata["presentation_name"],
                command_line=metadata["command_line"],
                tmux_pane_command=metadata.get("tmux_pane_command", ""),
                last_line=last_line,
                non_empty_lines_from_bottom=non_empty_lines,
                background_color_r=bg_r,
                background_color_g=bg_g,
                background_color_b=bg_b,
                background_color_light_r=bg_light_r,
                background_color_light_g=bg_light_g,
                background_color_light_b=bg_light_b,
                use_separate_colors=use_separate_colors,
            )
        )

    if metadata_cache is not None:
        metadata_cache.prune(active_ids)

    return entries
