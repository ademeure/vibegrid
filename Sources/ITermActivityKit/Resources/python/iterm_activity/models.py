from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class PollEntry:
    window_id: str
    x: float
    y: float
    width: float
    height: float
    badge_text: str = ""
    session_name: str = ""
    presentation_name: str = ""
    command_line: str = ""
    last_line: str = ""
    non_empty_lines_from_bottom: list[str] = field(default_factory=list)
    tty_active: bool = False
    background_color_r: int = 0
    background_color_g: int = 0
    background_color_b: int = 0
    background_color_light_r: int = 0
    background_color_light_g: int = 0
    background_color_light_b: int = 0
    use_separate_colors: bool = False

    def to_json(self) -> dict[str, object]:
        return {
            "window_id": self.window_id,
            "tty_active": self.tty_active,
            "x": self.x,
            "y": self.y,
            "width": self.width,
            "height": self.height,
            "badge_text": self.badge_text,
            "session_name": self.session_name,
            "presentation_name": self.presentation_name,
            "command_line": self.command_line,
            "last_line": self.last_line,
            "non_empty_lines_from_bottom": list(self.non_empty_lines_from_bottom),
            "background_color_r": self.background_color_r,
            "background_color_g": self.background_color_g,
            "background_color_b": self.background_color_b,
            "background_color_light_r": self.background_color_light_r,
            "background_color_light_g": self.background_color_light_g,
            "background_color_light_b": self.background_color_light_b,
            "use_separate_colors": self.use_separate_colors,
        }

    @classmethod
    def from_json(cls, value: dict[str, object]) -> "PollEntry":
        return cls(
            window_id=str(value.get("window_id", "")).strip(),
            tty_active=bool(value.get("tty_active", False)),
            x=float(value.get("x", 0) or 0),
            y=float(value.get("y", 0) or 0),
            width=float(value.get("width", 0) or 0),
            height=float(value.get("height", 0) or 0),
            badge_text=str(value.get("badge_text", "") or "").strip(),
            session_name=str(value.get("session_name", "") or "").strip(),
            presentation_name=str(value.get("presentation_name", "") or "").strip(),
            command_line=str(value.get("command_line", "") or "").strip(),
            last_line=str(value.get("last_line", "") or "").strip(),
            non_empty_lines_from_bottom=[
                str(item).strip()
                for item in list(value.get("non_empty_lines_from_bottom", []) or [])
                if str(item).strip()
            ],
        )


@dataclass(frozen=True)
class ResolvedActivity:
    status: str
    badge_text: str
    session_name: str
    last_line: str
    profile_id: str
    reason: str
    detail: str = ""
    semantic_lines: list[str] = field(default_factory=list)

    @property
    def semantic_line_count(self) -> int:
        return len(self.semantic_lines)

    def to_json(self) -> dict[str, object]:
        return {
            "status": self.status,
            "badge_text": self.badge_text,
            "session_name": self.session_name,
            "last_line": self.last_line,
            "profile_id": self.profile_id,
            "reason": self.reason,
            "detail": self.detail,
            "semantic_lines": list(self.semantic_lines),
            "semantic_line_count": self.semantic_line_count,
        }
