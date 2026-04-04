from __future__ import annotations

from dataclasses import dataclass
import time
from typing import Optional

from .models import PollEntry, ResolvedActivity
from .profiles import ResolvedProfile, resolved_profile_for_entry

# HACK: When "thinking with X effort" is visible, iTerm may not re-render
# for extended periods (the model is thinking, no output). Use a longer
# hold to avoid the detector seeing no changes and reporting idle.
THINKING_HOLD_SECONDS = 15.0


@dataclass(frozen=True)
class RuleMatch:
    id: str
    line: str


@dataclass(frozen=True)
class ActiveHold:
    reason: str
    detail: str
    expires_at: float


@dataclass
class WindowState:
    has_seen_window: bool = False
    last_semantic_lines: list[str] | None = None
    last_recent_active_rule_match: Optional[RuleMatch] = None
    last_recent_input_rule_match: Optional[RuleMatch] = None
    meaningful_change_streak: int = 0
    active_hold: Optional[ActiveHold] = None

    def __post_init__(self) -> None:
        if self.last_semantic_lines is None:
            self.last_semantic_lines = []


class Detector:
    def __init__(self, max_semantic_lines: int = 24, max_polled_non_empty_lines: int = 60):
        self.max_semantic_lines = max_semantic_lines
        self.max_polled_non_empty_lines = max_polled_non_empty_lines
        self._state_by_window_id: dict[str, WindowState] = {}

    def resolve(self, entries: list[PollEntry], now: float | None = None) -> dict[str, ResolvedActivity]:
        if now is None:
            now = time.monotonic()

        next_state_by_window_id: dict[str, WindowState] = {}
        resolved_by_window_id: dict[str, ResolvedActivity] = {}

        for entry in entries:
            normalized_lines = self._normalized_non_empty_lines(entry.non_empty_lines_from_bottom)
            normalized_lowercased_lines = [line.lower() for line in normalized_lines]
            profile = resolved_profile_for_entry(entry, normalized_lowercased_lines)
            recent_lines = normalized_lowercased_lines[: profile.activity_tuning.active_rule_lookback_lines]
            recent_active_rule_match = self._first_matching_rule(recent_lines, profile.first_active_rule)
            recent_input_candidate_lines = [
                line
                for line in recent_lines
                if (profile.first_chrome_rule(line) is None or profile.first_chrome_rule(line) == "slash-command")
            ]
            recent_input_rule_match = self._first_matching_rule(
                recent_input_candidate_lines,
                profile.first_input_rule,
            )
            semantic_lines = self._semantic_body_lines(normalized_lines, profile)
            previous_state = self._state_by_window_id.get(entry.window_id, WindowState())
            next_state = WindowState(
                has_seen_window=previous_state.has_seen_window,
                last_semantic_lines=list(previous_state.last_semantic_lines),
                last_recent_active_rule_match=previous_state.last_recent_active_rule_match,
                last_recent_input_rule_match=previous_state.last_recent_input_rule_match,
                meaningful_change_streak=previous_state.meaningful_change_streak,
                active_hold=previous_state.active_hold,
            )

            has_semantic_body = bool(semantic_lines)
            changed_line_count = self._semantic_line_delta_count(previous_state.last_semantic_lines, semantic_lines)
            character_delta = self._semantic_character_delta_estimate(previous_state.last_semantic_lines, semantic_lines)
            body_changed = has_semantic_body and previous_state.last_semantic_lines != semantic_lines
            meaningful_body_changed = (
                previous_state.has_seen_window
                and bool(previous_state.last_semantic_lines)
                and body_changed
                and (
                    changed_line_count >= profile.activity_tuning.minimum_changed_semantic_lines
                    or character_delta >= profile.activity_tuning.minimum_semantic_character_delta
                )
            )

            has_active_hold = previous_state.active_hold is not None and now < previous_state.active_hold.expires_at

            if recent_active_rule_match and self._should_trigger_visible_active_rule(
                recent_active_rule_match,
                previous_state,
                profile,
            ):
                next_state.meaningful_change_streak = 0
                detail = self._summarize_semantic_line(recent_active_rule_match.line)
                # HACK: "thinking with X effort" can stall iTerm rendering for
                # extended periods, so use a longer hold to avoid false idle.
                hold_seconds = (
                    THINKING_HOLD_SECONDS
                    if recent_active_rule_match.id == "thinking-effort"
                    else profile.activity_tuning.active_rule_hold_seconds
                )
                next_state.active_hold = ActiveHold(
                    reason=f"rule:{recent_active_rule_match.id}",
                    detail=detail,
                    expires_at=now + hold_seconds,
                )
                status = "active"
                reason = next_state.active_hold.reason
            elif recent_input_rule_match and self._should_trigger_input_rule(
                recent_input_rule_match,
                previous_state,
            ):
                next_state.meaningful_change_streak = 0
                detail = self._summarize_semantic_line(recent_input_rule_match.line)
                next_state.active_hold = ActiveHold(
                    reason=f"input:{recent_input_rule_match.id}",
                    detail=detail,
                    expires_at=now + profile.activity_tuning.input_hold_seconds,
                )
                status = "active"
                reason = next_state.active_hold.reason
            elif meaningful_body_changed:
                next_state.meaningful_change_streak += 1
                if (
                    next_state.meaningful_change_streak
                    >= profile.activity_tuning.required_consecutive_meaningful_changes
                ):
                    detail = self._semantic_line_change_summary(
                        previous_state.last_semantic_lines,
                        semantic_lines,
                    )
                    next_state.active_hold = ActiveHold(
                        reason="meaningful-body-change",
                        detail=detail,
                        expires_at=now + profile.activity_tuning.meaningful_change_hold_seconds,
                    )
                    status = "active"
                    reason = "meaningful-body-change"
                else:
                    next_state.active_hold = None
                    status = "idle"
                    reason = "warming-up"
                    detail = self._semantic_line_change_summary(
                        previous_state.last_semantic_lines,
                        semantic_lines,
                    )
            elif has_active_hold and previous_state.active_hold is not None:
                next_state.meaningful_change_streak = 0
                next_state.active_hold = previous_state.active_hold
                status = "active"
                reason = f"hold:{previous_state.active_hold.reason}"
                detail = previous_state.active_hold.detail
            elif not has_semantic_body:
                next_state.meaningful_change_streak = 0
                next_state.active_hold = None
                status = "idle"
                reason = "no-semantic-body"
                detail = ""
            elif not previous_state.has_seen_window or not previous_state.last_semantic_lines:
                next_state.meaningful_change_streak = 0
                next_state.active_hold = None
                status = "idle"
                reason = "baseline"
                detail = ""
            else:
                next_state.meaningful_change_streak = 0
                next_state.active_hold = None
                status = "idle"
                reason = "body-noise" if body_changed else "steady"
                detail = (
                    self._semantic_line_change_summary(previous_state.last_semantic_lines, semantic_lines)
                    if body_changed
                    else ""
                )

            if "detail" not in locals():
                detail = ""

            next_state.has_seen_window = True
            next_state.last_semantic_lines = semantic_lines
            next_state.last_recent_active_rule_match = recent_active_rule_match
            next_state.last_recent_input_rule_match = recent_input_rule_match

            next_state_by_window_id[entry.window_id] = next_state
            resolved_by_window_id[entry.window_id] = ResolvedActivity(
                status=status,
                badge_text=entry.badge_text,
                session_name=entry.session_name,
                last_line=entry.last_line,
                profile_id=profile.profile_id,
                reason=reason,
                detail=detail,
                semantic_lines=semantic_lines,
            )
            del detail

        self._state_by_window_id = next_state_by_window_id
        return resolved_by_window_id

    def semantic_body_lines(self, non_empty_lines_from_bottom: list[str]) -> list[str]:
        normalized_lines = self._normalized_non_empty_lines(non_empty_lines_from_bottom)
        profile = resolved_profile_for_entry(
            PollEntry(
                window_id="",
                tty_active=False,
                x=0,
                y=0,
                width=0,
                height=0,
                non_empty_lines_from_bottom=non_empty_lines_from_bottom,
            ),
            [line.lower() for line in normalized_lines],
        )
        return self._semantic_body_lines(normalized_lines, profile)

    def semantic_body_signature(self, non_empty_lines_from_bottom: list[str]) -> str:
        return "\n".join(self.semantic_body_lines(non_empty_lines_from_bottom))

    def normalized_semantic_line(self, raw_line: str) -> str:
        # Replace control characters with spaces (not strip) so that NUL bytes
        # used as padding in iTerm screen captures don't merge adjacent words.
        replaced = "".join(
            char if (char in ("\t", "\n") or not (ord(char) < 0x20 or 0x7F <= ord(char) <= 0x9F))
            else " "
            for char in raw_line
        )
        without_non_breaking_spaces = replaced.replace("\u00A0", " ")
        return " ".join(without_non_breaking_spaces.strip().split())

    def is_chrome_line(self, raw_line: str) -> bool:
        normalized = self.normalized_semantic_line(raw_line)
        profile = resolved_profile_for_entry(
            PollEntry(
                window_id="",
                tty_active=False,
                x=0,
                y=0,
                width=0,
                height=0,
                non_empty_lines_from_bottom=[raw_line],
            ),
            [normalized.lower()] if normalized else [],
        )
        return self._is_chrome_line(raw_line, profile)

    def _normalized_non_empty_lines(self, non_empty_lines_from_bottom: list[str]) -> list[str]:
        return [
            normalized
            for normalized in (self.normalized_semantic_line(line) for line in non_empty_lines_from_bottom)
            if normalized
        ]

    def _semantic_body_lines(
        self,
        normalized_lines_from_bottom: list[str],
        profile: ResolvedProfile,
    ) -> list[str]:
        if not normalized_lines_from_bottom:
            return []

        semantic_lines_from_bottom: list[str] = []
        started_semantic_body = False

        for line in normalized_lines_from_bottom:
            if not started_semantic_body:
                if self._is_chrome_line(line, profile):
                    continue
                started_semantic_body = True

            if self._is_chrome_line(line, profile):
                continue

            semantic_lines_from_bottom.append(line)
            if len(semantic_lines_from_bottom) >= self.max_semantic_lines:
                break

        semantic_lines_from_bottom.reverse()
        return semantic_lines_from_bottom

    def _is_chrome_line(self, raw_line: str, profile: ResolvedProfile) -> bool:
        line = raw_line.strip()
        if not line:
            return True

        lowercased = line.lower()
        if profile.first_chrome_rule(lowercased) is not None:
            return True

        if lowercased in {"claude", "claude code", ">", ">>", ">>>", "$", "%", "#", "running", "thinking"}:
            return True

        prefixes = [
            "esc to interrupt",
            "context ",
            "model ",
            "cwd ",
            "tokens ",
            "status ",
            "branch ",
            "session ",
            "press ",
            "tab to ",
            "enter to ",
            "ctrl-",
            "control-",
        ]
        if any(lowercased.startswith(prefix) for prefix in prefixes):
            return True

        if lowercased.startswith("http://") or lowercased.startswith("https://"):
            return False

        if __import__("re").search(r"^[>:$#%❯›].{0,6}$", line):
            return True

        if __import__("re").search(r"^(context|tokens)\s+\S+", line, flags=__import__("re").IGNORECASE):
            return True

        return False

    def _first_matching_rule(
        self,
        lines: list[str],
        resolver,
    ) -> RuleMatch | None:
        for line in lines:
            rule_id = resolver(line)
            if rule_id is not None:
                return RuleMatch(id=rule_id, line=line)
        return None

    @staticmethod
    def _should_trigger_visible_active_rule(
        current: RuleMatch,
        previous: WindowState,
        profile: ResolvedProfile,
    ) -> bool:
        if current != previous.last_recent_active_rule_match:
            return previous.has_seen_window or profile.activity_tuning.activates_immediately_on_visible_active_rule
        return False

    @staticmethod
    def _should_trigger_input_rule(current: RuleMatch, previous: WindowState) -> bool:
        return current != previous.last_recent_input_rule_match and previous.has_seen_window

    @staticmethod
    def _semantic_line_delta_count(previous: list[str], current: list[str]) -> int:
        max_count = max(len(previous), len(current))
        delta_count = 0
        for index in range(max_count):
            previous_line = previous[index] if index < len(previous) else None
            current_line = current[index] if index < len(current) else None
            if previous_line != current_line:
                delta_count += 1
        return delta_count

    def _semantic_character_delta_estimate(self, previous: list[str], current: list[str]) -> int:
        max_count = max(len(previous), len(current))
        delta = 0
        for index in range(max_count):
            previous_line = previous[index] if index < len(previous) else None
            current_line = current[index] if index < len(current) else None
            if previous_line is not None and current_line is not None:
                if previous_line != current_line:
                    delta += self._line_character_delta_estimate(previous_line, current_line)
            elif previous_line is not None:
                delta += len(previous_line)
            elif current_line is not None:
                delta += len(current_line)
        return delta

    @staticmethod
    def _line_character_delta_estimate(previous: str, current: str) -> int:
        previous_chars = list(previous)
        current_chars = list(current)

        prefix = 0
        while prefix < min(len(previous_chars), len(current_chars)) and previous_chars[prefix] == current_chars[prefix]:
            prefix += 1

        suffix = 0
        while (
            suffix < min(len(previous_chars) - prefix, len(current_chars) - prefix)
            and previous_chars[len(previous_chars) - 1 - suffix] == current_chars[len(current_chars) - 1 - suffix]
        ):
            suffix += 1

        previous_changed = max(len(previous_chars) - prefix - suffix, 0)
        current_changed = max(len(current_chars) - prefix - suffix, 0)
        return previous_changed + current_changed

    def _semantic_line_change_summary(self, previous: list[str], current: list[str]) -> str:
        max_count = max(len(previous), len(current))
        changes: list[str] = []
        for index in range(max_count):
            previous_line = previous[index] if index < len(previous) else None
            current_line = current[index] if index < len(current) else None
            if previous_line == current_line:
                continue
            changes.append(
                f"[{index}] {self._summarize_semantic_line(previous_line)} -> {self._summarize_semantic_line(current_line)}"
            )
            if len(changes) >= 3:
                break
        return " | ".join(changes)

    @staticmethod
    def _summarize_semantic_line(line: str | None) -> str:
        if line is None:
            return "∅"
        compact = line.replace("\n", " ")
        if len(compact) <= 120:
            return compact
        return compact[:117] + "..."
