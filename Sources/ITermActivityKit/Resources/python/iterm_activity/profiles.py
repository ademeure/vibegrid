from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Callable

from .models import PollEntry


@dataclass(frozen=True)
class ActivityTuning:
    required_consecutive_meaningful_changes: int
    minimum_changed_semantic_lines: int
    minimum_semantic_character_delta: int
    active_rule_lookback_lines: int
    activates_immediately_on_visible_active_rule: bool
    active_rule_hold_seconds: float
    input_hold_seconds: float
    meaningful_change_hold_seconds: float


@dataclass(frozen=True)
class LineRule:
    id: str
    matches: Callable[[str], bool]

    def applies(self, line: str) -> bool:
        return self.matches(line)


@dataclass(frozen=True)
class ProfileDefinition:
    id: str
    kind: str
    matches_entry: Callable[[PollEntry, list[str]], bool]
    chrome_rules: list[LineRule]
    active_rules: list[LineRule]
    input_rules: list[LineRule]
    activity_tuning: ActivityTuning | None


@dataclass(frozen=True)
class ResolvedProfile:
    profile_id: str
    base_id: str
    overlay_ids: list[str]
    chrome_rules: list[LineRule]
    active_rules: list[LineRule]
    input_rules: list[LineRule]
    activity_tuning: ActivityTuning

    def first_chrome_rule(self, line: str) -> str | None:
        for rule in self.chrome_rules:
            if rule.applies(line):
                return rule.id
        return None

    def first_active_rule(self, line: str) -> str | None:
        for rule in self.active_rules:
            if rule.applies(line):
                return rule.id
        return None

    def first_input_rule(self, line: str) -> str | None:
        for rule in self.input_rules:
            if rule.applies(line):
                return rule.id
        return None


DEFAULT_ACTIVITY_TUNING = ActivityTuning(
    required_consecutive_meaningful_changes=1,
    minimum_changed_semantic_lines=1,
    minimum_semantic_character_delta=2,
    active_rule_lookback_lines=16,
    activates_immediately_on_visible_active_rule=True,
    active_rule_hold_seconds=5.0,
    input_hold_seconds=1.2,
    meaningful_change_hold_seconds=1.5,
)


def canonical_rule_text(text: str) -> str:
    return re.sub(r"\s+", "", text.lower())


def contains_rule(rule_id: str, needles: list[str]) -> LineRule:
    canonical_needles = [canonical_rule_text(needle) for needle in needles]

    def matches(line: str) -> bool:
        canonical_line = canonical_rule_text(line)
        return all(needle in canonical_line for needle in canonical_needles)

    return LineRule(id=rule_id, matches=matches)


def prefix_rule(rule_id: str, prefixes: list[str]) -> LineRule:
    canonical_prefixes = [canonical_rule_text(prefix) for prefix in prefixes]

    def matches(line: str) -> bool:
        canonical_line = canonical_rule_text(line)
        return any(canonical_line.startswith(prefix) for prefix in canonical_prefixes)

    return LineRule(id=rule_id, matches=matches)


def regex_rule(rule_id: str, pattern: str) -> LineRule:
    compiled = re.compile(pattern)
    return LineRule(id=rule_id, matches=lambda line: compiled.search(line) is not None)


def command_line_contains_command(command_line: str, command: str) -> bool:
    pattern = rf"(?:^|\s|/){re.escape(command)}(?:\s|$)"
    return re.search(pattern, command_line) is not None


GENERIC_CHROME_RULES = [
    contains_rule("interrupt-footer", ["esc to interrupt"]),
    contains_rule("permission-footer", ["bypass permissions on", "shift+tab to cycle"]),
    contains_rule("dialog-dismissed", ["status dialog dismissed"]),
    contains_rule("companion-muted", ["companion muted"]),
    contains_rule("compacted-tip", ["compacted tip:"]),
    contains_rule("conversation-compacted", ["conversation compacted"]),
    contains_rule("version-footer", ["current:", "latest:"]),
    prefix_rule("slash-command", ["❯ /", "› /", "> /"]),
    prefix_rule("status-subline", ["⎿ "]),
    regex_rule("horizontal-rule", r"^[─━-]{12,}(?:\s+[\.\(\)/\\_✦-]+)?$"),
    regex_rule("buddy-ascii", r"^(?:\.----\.|\( ?[✦\-] ?[✦\-] ?\)|\(______\)|/\\/\\/\\/\\)$"),
]

CLAUDE_CHROME_RULES = [
    contains_rule("model-confirmation", ["set model to"]),
    contains_rule("buddy-command", ["/buddy"]),
    contains_rule("background-hint", ["ctrl+b to run in background"]),
    regex_rule("claude-buddy-prompt", r"^[❯›>]\s*(?:.*\s)?\(\s*[✦*•oO\-. ]+\s*\)$"),
    regex_rule("claude-transient-prompt-fragment", r"^(?:[.,:;'\"`]?>|[oO])$"),
]

CODEX_CHROME_RULES = [
    regex_rule("codex-footer", r"^gpt-[^·]+·\s*\d+% left · .+$"),
    contains_rule("codex-queue-hint", ["tab to queue message"]),
]

TMUX_CHROME_RULES = [
    regex_rule("tmux-status-line", r"^\[[^\]]+\]\s*\d+:[^\s]+.*\d{2}:\d{2}"),
]

GENERIC_ACTIVE_RULES = [
    contains_rule("working-spinner", ["working (", "esc to interrupt"]),
]

CLAUDE_ACTIVE_RULES = [
    contains_rule("compacting-conversation-spinner", ["compacting conversation"]),
    # HACK: "thinking with X effort" lines indicate the model is actively
    # thinking but iTerm may not re-render for extended periods, causing the
    # detector to see no screen changes and incorrectly report idle.
    # Uses a longer hold (15s) — see THINKING_HOLD_SECONDS in detector.py.
    regex_rule("thinking-effort", r"thinking with \w+ effort"),
]

CODEX_ACTIVE_RULES = [
    contains_rule("codex-working-spinner", ["working ("]),
]

INTERACTIVE_PROMPT_RULES = [
    regex_rule("prompt-edit", r"^[❯›>]\s+.+$"),
]


_CLAUDE_CODE_VERSION_FOOTER_RE = re.compile(r"current:\s*\d+\.\d+\.\d+\s*·\s*latest:\s*\d+\.\d+\.\d+")
_CLAUDE_CODE_TOKEN_INDICATOR_RE = re.compile(r"[↓↑]\s*[\d.]+k?\s*tokens")


def _lines_match_claude_code(normalized_lines: list[str]) -> bool:
    """Detect Claude Code from visible screen content (e.g. inside tmux)."""
    for line in normalized_lines:
        if (
            "/buddy" in line
            or "compacting conversation" in line
            or "conversation compacted" in line
            or "bypass permissions on" in line
            or "ctrl+b to run in background" in line
            or _CLAUDE_CODE_VERSION_FOOTER_RE.search(line) is not None
            or _CLAUDE_CODE_TOKEN_INDICATOR_RE.search(line) is not None
        ):
            return True
    return False


DEFAULT_BASE_PROFILE = ProfileDefinition(
    id="default",
    kind="base",
    matches_entry=lambda _entry, _normalized_lines: True,
    chrome_rules=GENERIC_CHROME_RULES,
    active_rules=GENERIC_ACTIVE_RULES,
    input_rules=[],
    activity_tuning=DEFAULT_ACTIVITY_TUNING,
)

CLAUDE_CODE_BASE_PROFILE = ProfileDefinition(
    id="claude-code",
    kind="base",
    matches_entry=lambda entry, normalized_lines: (
        "claude code" in entry.session_name.lower()
        or "(claude)" in entry.session_name.lower()
        or "claude code" in entry.presentation_name.lower()
        or command_line_contains_command(entry.command_line.lower(), "claude")
        or _lines_match_claude_code(normalized_lines)
    ),
    chrome_rules=GENERIC_CHROME_RULES + CLAUDE_CHROME_RULES,
    active_rules=CLAUDE_ACTIVE_RULES + GENERIC_ACTIVE_RULES,
    input_rules=INTERACTIVE_PROMPT_RULES,
    activity_tuning=ActivityTuning(
        required_consecutive_meaningful_changes=1,
        minimum_changed_semantic_lines=1,
        minimum_semantic_character_delta=4,
        active_rule_lookback_lines=16,
        activates_immediately_on_visible_active_rule=True,
        active_rule_hold_seconds=6.0,
        input_hold_seconds=1.2,
        meaningful_change_hold_seconds=2.0,
    ),
)

CODEX_BASE_PROFILE = ProfileDefinition(
    id="codex",
    kind="base",
    matches_entry=lambda entry, _normalized_lines: (
        "(codex" in entry.session_name.lower()
        or "codex" in entry.presentation_name.lower()
        or command_line_contains_command(entry.command_line.lower(), "codex")
    ),
    chrome_rules=GENERIC_CHROME_RULES + CODEX_CHROME_RULES,
    active_rules=CODEX_ACTIVE_RULES + GENERIC_ACTIVE_RULES,
    input_rules=INTERACTIVE_PROMPT_RULES,
    activity_tuning=ActivityTuning(
        required_consecutive_meaningful_changes=1,
        minimum_changed_semantic_lines=1,
        minimum_semantic_character_delta=2,
        active_rule_lookback_lines=16,
        activates_immediately_on_visible_active_rule=True,
        active_rule_hold_seconds=6.0,
        input_hold_seconds=1.2,
        meaningful_change_hold_seconds=1.75,
    ),
)

TMUX_OVERLAY_PROFILE = ProfileDefinition(
    id="tmux",
    kind="overlay",
    matches_entry=lambda entry, normalized_lines: (
        command_line_contains_command(entry.command_line.lower(), "tmux")
        or any(
            re.search(r"^\[[^\]]+\]\s*\d+:[^\s]+.*\d{2}:\d{2}", line) is not None
            for line in normalized_lines
        )
    ),
    chrome_rules=TMUX_CHROME_RULES,
    active_rules=[],
    input_rules=[],
    activity_tuning=None,
)

BASE_PROFILES = [CLAUDE_CODE_BASE_PROFILE, CODEX_BASE_PROFILE, DEFAULT_BASE_PROFILE]
OVERLAY_PROFILES = [TMUX_OVERLAY_PROFILE]


def resolved_profile_for_entry(
    entry: PollEntry,
    normalized_lines: list[str],
    sticky_base_id: str | None = None,
) -> ResolvedProfile:
    base_profile = next(
        (profile for profile in BASE_PROFILES if profile.matches_entry(entry, normalized_lines)),
        DEFAULT_BASE_PROFILE,
    )
    # Sticky profile: if detection fell back to default but we previously
    # detected a more specific profile, keep using it.
    if base_profile.id == "default" and sticky_base_id and sticky_base_id != "default":
        sticky_base = next((p for p in BASE_PROFILES if p.id == sticky_base_id), None)
        if sticky_base is not None:
            base_profile = sticky_base
    overlays = [profile for profile in OVERLAY_PROFILES if profile.matches_entry(entry, normalized_lines)]
    overlay_ids = [profile.id for profile in overlays]
    profile_id = "+".join([base_profile.id] + overlay_ids)

    return ResolvedProfile(
        profile_id=profile_id,
        base_id=base_profile.id,
        overlay_ids=overlay_ids,
        chrome_rules=base_profile.chrome_rules + [rule for overlay in overlays for rule in overlay.chrome_rules],
        active_rules=base_profile.active_rules + [rule for overlay in overlays for rule in overlay.active_rules],
        input_rules=base_profile.input_rules + [rule for overlay in overlays for rule in overlay.input_rules],
        activity_tuning=base_profile.activity_tuning or DEFAULT_ACTIVITY_TUNING,
    )
