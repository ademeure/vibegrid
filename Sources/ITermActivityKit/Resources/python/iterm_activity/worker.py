from __future__ import annotations

import asyncio
import json
import sys
import traceback

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


async def _handle_poll(
    connection,
    detector: Detector,
    metadata_cache: CachedWindowMetadata,
    request_id: object,
    max_polled_non_empty_lines: int,
) -> None:
    entries = await collect_window_snapshots(
        connection, max_polled_non_empty_lines, metadata_cache
    )
    activities = detector.resolve(entries)
    _write_response(
        {
            "id": request_id,
            "ok": True,
            "entries": [entry.to_json() for entry in entries],
            "activities": {
                window_id: activity.to_json()
                for window_id, activity in activities.items()
            },
        }
    )


async def _worker_main(connection) -> None:
    detector = Detector()
    metadata_cache = CachedWindowMetadata(ttl=1.0)

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

            if op != "poll":
                _write_response({"id": request_id, "ok": False, "error": f"unknown op: {op}"})
                continue

            max_polled_non_empty_lines = int(request.get("max_polled_non_empty_lines", 60) or 60)
            await _handle_poll(
                connection, detector, metadata_cache, request_id, max_polled_non_empty_lines
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
