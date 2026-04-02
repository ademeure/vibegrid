from __future__ import annotations

import re
import time

import iterm2

from .models import PollEntry


TMUX_SESSION_PATTERN = re.compile(r"tmux\s+(?:attach|a|new|new-session)\s+.*?-t\s+\W*(\w[\w-]*)")


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
            first_visible = int(line_info.first_visible_line_number)
            requested_lines = min(visible_height, max_polled_non_empty_lines)
            first_line = first_visible + max(0, visible_height - requested_lines)
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

    try:
        command_line = str(await session.async_get_variable("commandLine") or "").strip()
        presentation_name = str(await session.async_get_variable("presentationName") or "").strip()
        match = TMUX_SESSION_PATTERN.search(command_line)
        if match:
            session_name = match.group(1)
        elif presentation_name and presentation_name not in {"-zsh", "zsh", "bash", "-bash", "fish", "login"}:
            session_name = presentation_name
    except Exception:
        pass

    return {
        "badge_text": badge_text,
        "command_line": command_line,
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
            metadata = {"badge_text": "", "command_line": "", "presentation_name": "", "session_name": ""}

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
                last_line=last_line,
                non_empty_lines_from_bottom=non_empty_lines,
            )
        )

    if metadata_cache is not None:
        metadata_cache.prune(active_ids)

    return entries
