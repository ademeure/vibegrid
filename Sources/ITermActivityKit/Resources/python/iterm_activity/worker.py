from __future__ import annotations

import asyncio
import json
import sys
import traceback
from dataclasses import dataclass

import iterm2

from .collector import CachedWindowMetadata, collect_window_snapshots
from .detector import Detector


def _write_response(payload: dict[str, object]) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


async def _read_stdin_line() -> bytes:
    return await asyncio.to_thread(sys.stdin.buffer.readline)


async def _handle_set_name(
    connection,
    request_id: object,
    request: dict,
) -> None:
    window_id = request.get("window_id", "")
    name = request.get("name", "")
    if not window_id:
        _write_response({"id": request_id, "ok": False, "error": "missing window_id"})
        return

    app = await iterm2.async_get_app(connection)
    for window in app.windows:
        if str(window.window_id) == window_id:
            try:
                await window.async_set_title(name)
                session = window.current_tab.current_session
                await session.async_set_name(name)
                _write_response({"id": request_id, "ok": True})
            except Exception:
                _write_response({"id": request_id, "ok": False, "error": traceback.format_exc()})
            return
    _write_response({"id": request_id, "ok": False, "error": f"window {window_id} not found"})


async def _handle_set_background_color(
    connection,
    request_id: object,
    request: dict,
) -> None:
    window_id = request.get("window_id", "")
    r = int(request.get("r", 0))
    g = int(request.get("g", 0))
    b = int(request.get("b", 0))
    if not window_id:
        _write_response({"id": request_id, "ok": False, "error": "missing window_id"})
        return

    app = await iterm2.async_get_app(connection)
    for window in app.windows:
        if str(window.window_id) == window_id:
            try:
                for tab in window.tabs:
                    for session in tab.sessions:
                        profile = await session.async_get_profile()
                        await profile.async_set_background_color(
                            iterm2.Color(r, g, b)
                        )
                _write_response({"id": request_id, "ok": True})
            except Exception:
                _write_response({"id": request_id, "ok": False, "error": traceback.format_exc()})
            return
    _write_response({"id": request_id, "ok": False, "error": f"window {window_id} not found"})


async def _handle_set_tab_color(
    connection,
    request_id: object,
    request: dict,
) -> None:
    window_id = request.get("window_id", "")
    r = int(request.get("r", 0))
    g = int(request.get("g", 0))
    b = int(request.get("b", 0))
    enabled = bool(request.get("enabled", True))
    if not window_id:
        _write_response({"id": request_id, "ok": False, "error": "missing window_id"})
        return

    app = await iterm2.async_get_app(connection)
    for window in app.windows:
        if str(window.window_id) == window_id:
            try:
                for tab in window.tabs:
                    for session in tab.sessions:
                        profile = await session.async_get_profile()
                        await profile.async_set_use_tab_color(enabled)
                        if enabled:
                            await profile.async_set_tab_color(
                                iterm2.Color(r, g, b)
                            )
                _write_response({"id": request_id, "ok": True})
            except Exception:
                _write_response({"id": request_id, "ok": False, "error": traceback.format_exc()})
            return
    _write_response({"id": request_id, "ok": False, "error": f"window {window_id} not found"})


async def _handle_get_background_color(
    connection,
    request_id: object,
    request: dict,
) -> None:
    window_id = request.get("window_id", "")
    if not window_id:
        _write_response({"id": request_id, "ok": False, "error": "missing window_id"})
        return

    app = await iterm2.async_get_app(connection)
    for window in app.windows:
        if str(window.window_id) == window_id:
            try:
                session = window.current_tab.current_session
                profile = await session.async_get_profile()
                bg = profile.background_color
                _write_response({
                    "id": request_id, "ok": True,
                    "r": bg.red, "g": bg.green, "b": bg.blue,
                })
            except Exception:
                _write_response({"id": request_id, "ok": False, "error": traceback.format_exc()})
            return
    _write_response({"id": request_id, "ok": False, "error": f"window {window_id} not found"})


async def _handle_poll(
    connection,
    detector: Detector,
    metadata_cache: CachedWindowMetadata,
    request_id: object,
    max_polled_non_empty_lines: int,
    commands: list[dict] | None = None,
    original_bg_by_profile_guid: dict[str, tuple[int, int, int]] | None = None,
) -> None:
    entries = await collect_window_snapshots(
        connection, max_polled_non_empty_lines, metadata_cache,
        original_bg_by_profile_guid=original_bg_by_profile_guid,
    )
    activities = detector.resolve(entries)

    # Process batched commands efficiently — group by window, fetch profile once
    command_results: list[dict] = []
    if commands:
        try:
            app = await iterm2.async_get_app(connection)
            windows_by_id = {str(w.window_id): w for w in app.windows}
            for cmd in commands:
                cmd_op = cmd.get("op", "")
                window_id = cmd.get("window_id", "")
                try:
                    window = windows_by_id.get(window_id)
                    if window is None:
                        command_results.append({"op": cmd_op, "ok": False, "error": f"window {window_id} not found"})
                        continue
                    session = window.current_tab.current_session
                    profile = await session.async_get_profile()
                    if cmd_op == "set_background_color":
                        dark_color = iterm2.Color(int(cmd.get("r", 0)), int(cmd.get("g", 0)), int(cmd.get("b", 0)))
                        use_separate = getattr(profile, 'use_separate_colors_for_light_and_dark_mode', None)
                        if use_separate:
                            await profile.async_set_background_color_dark(dark_color)
                            if "r_light" in cmd:
                                light_color = iterm2.Color(int(cmd["r_light"]), int(cmd["g_light"]), int(cmd["b_light"]))
                            else:
                                light_color = dark_color
                            await profile.async_set_background_color_light(light_color)
                        else:
                            await profile.async_set_background_color(dark_color)
                    elif cmd_op == "set_tab_color":
                        enabled = bool(cmd.get("enabled", True))
                        use_separate = getattr(profile, 'use_separate_colors_for_light_and_dark_mode', None)
                        if use_separate:
                            await profile.async_set_use_tab_color_dark(enabled)
                            if enabled:
                                await profile.async_set_tab_color_dark(
                                    iterm2.Color(int(cmd.get("r", 0)), int(cmd.get("g", 0)), int(cmd.get("b", 0)))
                                )
                        else:
                            await profile.async_set_use_tab_color(enabled)
                            if enabled:
                                await profile.async_set_tab_color(
                                    iterm2.Color(int(cmd.get("r", 0)), int(cmd.get("g", 0)), int(cmd.get("b", 0)))
                                )
                    else:
                        command_results.append({"op": cmd_op, "ok": False, "error": f"unknown cmd op: {cmd_op}"})
                        continue
                    command_results.append({"op": cmd_op, "ok": True})
                except Exception:
                    command_results.append({"op": cmd_op, "ok": False, "error": traceback.format_exc()})
        except Exception:
            command_results.append({"op": "batch", "ok": False, "error": traceback.format_exc()})

    _write_response(
        {
            "id": request_id,
            "ok": True,
            "entries": [entry.to_json() for entry in entries],
            "activities": {
                window_id: activity.to_json()
                for window_id, activity in activities.items()
            },
            "command_results": command_results,
        }
    )




@dataclass
class ProfileBgInfo:
    dark: tuple[int, int, int]
    light: tuple[int, int, int]
    use_separate: bool


async def _build_profile_bg_cache(connection) -> dict[str, ProfileBgInfo]:
    """Build a map of profile GUID → original background colors from the profile list.

    This reads from the PROFILE LIST (Preferences > Profiles), not session overrides,
    so it always returns the true original background even if sessions have been tinted.
    """
    cache: dict[str, ProfileBgInfo] = {}
    try:
        all_profiles = await iterm2.PartialProfile.async_get(connection)
        for profile in all_profiles:
            try:
                use_separate = bool(getattr(profile, 'use_separate_colors_for_light_and_dark_mode', None))
                guid = profile.guid
                if not guid:
                    continue
                if use_separate:
                    bg_dark = profile.background_color_dark
                    bg_light = profile.background_color_light
                    cache[guid] = ProfileBgInfo(
                        dark=(round(bg_dark.red), round(bg_dark.green), round(bg_dark.blue)),
                        light=(round(bg_light.red), round(bg_light.green), round(bg_light.blue)),
                        use_separate=True,
                    )
                else:
                    bg = profile.background_color
                    rgb = (round(bg.red), round(bg.green), round(bg.blue))
                    cache[guid] = ProfileBgInfo(dark=rgb, light=rgb, use_separate=False)
            except Exception:
                pass
    except Exception:
        pass
    return cache


async def _worker_main(connection) -> None:
    detector = Detector()
    metadata_cache = CachedWindowMetadata(ttl=1.0)

    # Build profile background cache from the profile list (not session overrides)
    original_bg_by_profile_guid = await _build_profile_bg_cache(connection)

    while True:
        raw_line = await _read_stdin_line()
        if not raw_line:
            return

        request_id = None
        try:
            request = json.loads(raw_line.decode("utf-8"))
            request_id = request.get("id")
            op = request.get("op")

            if op == "shutdown":
                _write_response({"id": request_id, "ok": True, "shutdown": True})
                return

            if op == "set_name":
                await _handle_set_name(connection, request_id, request)
                continue

            if op == "set_background_color":
                await _handle_set_background_color(connection, request_id, request)
                continue

            if op == "set_tab_color":
                await _handle_set_tab_color(connection, request_id, request)
                continue

            if op == "get_background_color":
                await _handle_get_background_color(connection, request_id, request)
                continue

            if op != "poll":
                _write_response({"id": request_id, "ok": False, "error": f"unknown op: {op}"})
                continue

            max_polled_non_empty_lines = int(request.get("max_polled_non_empty_lines", 60) or 60)
            commands = request.get("commands") or []
            await _handle_poll(
                connection, detector, metadata_cache, request_id, max_polled_non_empty_lines,
                commands=commands,
                original_bg_by_profile_guid=original_bg_by_profile_guid,
            )
        except Exception:
            _write_response(
                {
                    "id": request_id,
                    "ok": False,
                    "error": traceback.format_exc(),
                }
            )


def main() -> None:
    iterm2.run_until_complete(_worker_main, retry=False)


if __name__ == "__main__":
    main()
