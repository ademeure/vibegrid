from __future__ import annotations

import re

import iterm2

from .models import PollEntry


TMUX_SESSION_PATTERN = re.compile(r"tmux\s+(?:attach|a|new|new-session)\s+.*?-t\s+\W*(\w[\w-]*)")


async def collect_window_snapshots(
    connection,
    max_polled_non_empty_lines: int,
) -> list[PollEntry]:
    app = await iterm2.async_get_app(connection)
    entries: list[PollEntry] = []

    for window in app.windows:
        badge_text = ""
        session_name = ""
        presentation_name = ""
        command_line = ""
        last_line = ""
        non_empty_lines: list[str] = []

        try:
            current_session = window.current_tab.current_session
        except Exception:
            current_session = None

        if current_session is not None:
            try:
                badge = await current_session.async_get_variable("badge")
                if isinstance(badge, str) and badge.strip():
                    badge_text = badge.strip()
            except Exception:
                pass

            try:
                command_line = str(await current_session.async_get_variable("commandLine") or "").strip()
                presentation_name = str(await current_session.async_get_variable("presentationName") or "").strip()
                match = TMUX_SESSION_PATTERN.search(command_line)
                if match:
                    session_name = match.group(1)
                elif presentation_name and presentation_name not in {"-zsh", "zsh", "bash", "-bash", "fish", "login"}:
                    session_name = presentation_name

                async with iterm2.Transaction(connection):
                    line_info = await current_session.async_get_line_info()
                    visible_height = max(1, int(line_info.mutable_area_height))
                    first_visible = int(line_info.first_visible_line_number)
                    requested_lines = min(visible_height, max_polled_non_empty_lines)
                    first_line = first_visible + max(0, visible_height - requested_lines)
                    lines = await current_session.async_get_contents(first_line, requested_lines)

                for line in reversed(lines):
                    candidate = line.string.strip()
                    if candidate:
                        if not last_line:
                            last_line = candidate[:240]
                        non_empty_lines.append(candidate[:240])
            except Exception:
                pass

        frame = window.frame
        entries.append(
            PollEntry(
                window_id=str(window.window_id),
                tty_active=False,
                x=float(frame.origin.x),
                y=float(frame.origin.y),
                width=float(frame.size.width),
                height=float(frame.size.height),
                badge_text=badge_text,
                session_name=session_name,
                presentation_name=presentation_name,
                command_line=command_line,
                last_line=last_line,
                non_empty_lines_from_bottom=non_empty_lines,
            )
        )

    return entries
