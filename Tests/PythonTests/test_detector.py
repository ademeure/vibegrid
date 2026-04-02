from __future__ import annotations

import pathlib
import sys
import unittest


PYTHON_PACKAGE_ROOT = (
    pathlib.Path(__file__).resolve().parents[2]
    / "Sources"
    / "ITermActivityKit"
    / "Resources"
    / "python"
)
if str(PYTHON_PACKAGE_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_PACKAGE_ROOT))

from iterm_activity import Detector, PollEntry  # noqa: E402


def make_poll_entry(
    *,
    window_id: str = "iterm-window-1",
    tty_active: bool,
    non_empty_lines_from_bottom: list[str],
    session_name: str = "local shell",
    presentation_name: str = "zsh",
    command_line: str = "zsh",
    last_line: str | None = None,
) -> PollEntry:
    return PollEntry(
        window_id=window_id,
        tty_active=tty_active,
        x=0,
        y=0,
        width=1200,
        height=800,
        badge_text="",
        session_name=session_name,
        presentation_name=presentation_name,
        command_line=command_line,
        last_line=last_line or (non_empty_lines_from_bottom[0] if non_empty_lines_from_bottom else ""),
        non_empty_lines_from_bottom=non_empty_lines_from_bottom,
    )


def claude_chrome_footer(token_suffix: str = "123") -> list[str]:
    return [
        "esc to interrupt",
        "context 82%",
        "model opus",
        "cwd /Users/arun/github/vibegrid",
        f"tokens {token_suffix}",
        "status Running",
        "> ",
        "claude",
    ]


def claude_window(*, token_suffix: str = "123", semantic_body_from_bottom: list[str]) -> list[str]:
    return claude_chrome_footer(token_suffix=token_suffix) + semantic_body_from_bottom


def static_bullet_window() -> list[str]:
    return [
        "- Quality: Perfect transcription verified on real speech",
        "- Memory: about 5 GB steady state",
        "- Speed: 180ms for 5s audio, 27-37x RTFx",
    ]


def claude_spinner_window(spinner_line: str) -> list[str]:
    return claude_window(
        semantic_body_from_bottom=[
            spinner_line,
            "Why V1 is better for your proxy: V1 is a dumb pipe that stays backend agnostic.",
            "That generality maps cleanly onto multiple STT providers.",
        ]
    )


def claude_thinking_window(thinking_line: str) -> list[str]:
    return claude_window(
        semantic_body_from_bottom=[
            thinking_line,
            "Most other STT providers do not have equivalent concepts like EagerEndOfTurn or TurnResumed.",
            "That generality maps cleanly onto multiple STT providers.",
        ]
    )


def quillnook_buddy_window(version_line: str) -> list[str]:
    return [
        version_line,
        "⏵⏵ bypass permissions on (shift+tab to cycle) 14 tokens Quillnook",
        "(______)",
        ".----.",
        "⎿ companion muted",
        "❯ /buddy off",
        "- Quality: Perfect transcription verified on real speech",
        "- Memory: about 5 GB steady state",
        "- Speed: 180ms for 5s audio, 27-37x RTFx",
    ]


def tmux_window(status_line: str) -> list[str]:
    return [
        status_line,
        "Most recent speech result was stable and already finalized.",
        "The runtime is not doing new work right now.",
    ]


def long_body_baseline() -> list[str]:
    return claude_window(
        semantic_body_from_bottom=[
            "This line will grow meaningfully across polls.",
            "We need semantic screen changes before a window turns active.",
            "The previous heuristic was tied too closely to tty mtime.",
            "Current plan: stabilize the activity detector against footer churn.",
        ]
    )


def long_body_changed_once() -> list[str]:
    return claude_window(
        token_suffix="124",
        semantic_body_from_bottom=[
            "This line will grow meaningfully across polls with a larger appended clause.",
            "We need semantic screen changes before a window turns active.",
            "The previous heuristic was tied too closely to tty mtime.",
            "Current plan: stabilize the activity detector against footer churn.",
        ]
    )


def long_body_changed_twice() -> list[str]:
    return claude_window(
        token_suffix="125",
        semantic_body_from_bottom=[
            "This line will grow meaningfully across polls with a larger appended clause and a second confirmation sentence.",
            "We need semantic screen changes before a window turns active.",
            "The previous heuristic was tied too closely to tty mtime.",
            "Current plan: stabilize the activity detector against footer churn.",
        ]
    )


def detector_time(seconds: float) -> float:
    return 1_000_000.0 + seconds


class DetectorTests(unittest.TestCase):
    def test_semantic_body_lines_strip_claude_chrome_footer(self) -> None:
        detector = Detector()
        semantic_lines = detector.semantic_body_lines(
            claude_window(
                semantic_body_from_bottom=[
                    "Bottom semantic line.",
                    "Another semantic line.",
                    "Top semantic line.",
                ]
            )
        )

        self.assertEqual(len(semantic_lines), 3)
        self.assertTrue(all(not detector.is_chrome_line(line) for line in semantic_lines))
        self.assertIn("Bottom semantic line.", semantic_lines)

    def test_semantic_body_lines_return_empty_for_chrome_only_window(self) -> None:
        detector = Detector()
        self.assertEqual(detector.semantic_body_lines(claude_chrome_footer()), [])

    def test_ignores_footer_only_churn(self) -> None:
        detector = Detector()

        first = detector.resolve([
            make_poll_entry(
                tty_active=True,
                non_empty_lines_from_bottom=claude_window(
                    token_suffix="123",
                    semantic_body_from_bottom=[
                        "Why V1 is better for your proxy: V1 is a dumb pipe - segments in, transcripts out.",
                        "That generality maps to every backend.",
                        "Flux's turn state machine is opinionated about the use case.",
                        "Most other STT providers do not have equivalent concepts like EagerEndOfTurn or TurnResumed.",
                    ],
                ),
            )
        ])
        second = detector.resolve([
            make_poll_entry(
                tty_active=True,
                non_empty_lines_from_bottom=claude_window(
                    token_suffix="124",
                    semantic_body_from_bottom=[
                        "Why V1 is better for your proxy: V1 is a dumb pipe - segments in, transcripts out.",
                        "That generality maps to every backend.",
                        "Flux's turn state machine is opinionated about the use case.",
                        "Most other STT providers do not have equivalent concepts like EagerEndOfTurn or TurnResumed.",
                    ],
                ),
            )
        ])

        self.assertEqual(first["iterm-window-1"].status, "idle")
        self.assertEqual(second["iterm-window-1"].status, "idle")

    def test_keeps_short_static_window_idle(self) -> None:
        detector = Detector()
        entry = make_poll_entry(tty_active=True, non_empty_lines_from_bottom=static_bullet_window())
        first = detector.resolve([entry])
        second = detector.resolve([entry])
        self.assertEqual(first["iterm-window-1"].status, "idle")
        self.assertEqual(second["iterm-window-1"].status, "idle")

    def test_whitespace_normalization_does_not_trigger_activity(self) -> None:
        detector = Detector()
        baseline = make_poll_entry(
            tty_active=True,
            non_empty_lines_from_bottom=[
                "Result line with single spaces",
                "Another stable line",
            ],
        )
        spacing_only_change = make_poll_entry(
            tty_active=True,
            non_empty_lines_from_bottom=[
                "Result   line   with   single   spaces",
                "Another stable line   ",
            ],
        )
        first = detector.resolve([baseline])
        second = detector.resolve([spacing_only_change])
        self.assertEqual(first["iterm-window-1"].status, "idle")
        self.assertEqual(second["iterm-window-1"].status, "idle")
        self.assertEqual(second["iterm-window-1"].reason, "steady")

    def test_meaningful_body_change_activates_default_profile_immediately(self) -> None:
        detector = Detector()
        first = detector.resolve([
            make_poll_entry(
                tty_active=True,
                non_empty_lines_from_bottom=[
                    "Most recent speech result was stable and finalized.",
                    "No new work is happening yet.",
                ],
            )
        ])
        second = detector.resolve([
            make_poll_entry(
                tty_active=True,
                non_empty_lines_from_bottom=[
                    "Most recent speech result was stable and finalized with a newly appended explanation.",
                    "No new work is happening yet.",
                ],
            )
        ])
        self.assertEqual(first["iterm-window-1"].status, "idle")
        self.assertEqual(second["iterm-window-1"].status, "active")
        self.assertEqual(second["iterm-window-1"].reason, "meaningful-body-change")

    def test_activity_hold_keeps_window_active_until_hold_expires(self) -> None:
        detector = Detector()
        detector.resolve(
            [make_poll_entry(tty_active=False, non_empty_lines_from_bottom=long_body_baseline())],
            now=detector_time(0),
        )
        second = detector.resolve(
            [make_poll_entry(tty_active=False, non_empty_lines_from_bottom=long_body_changed_once())],
            now=detector_time(1),
        )
        third = detector.resolve(
            [make_poll_entry(tty_active=False, non_empty_lines_from_bottom=long_body_changed_once())],
            now=detector_time(2),
        )
        expired = detector.resolve(
            [make_poll_entry(tty_active=False, non_empty_lines_from_bottom=long_body_changed_once())],
            now=detector_time(5),
        )

        self.assertEqual(second["iterm-window-1"].status, "active")
        self.assertEqual(third["iterm-window-1"].status, "active")
        self.assertEqual(third["iterm-window-1"].reason, "hold:meaningful-body-change")
        self.assertEqual(expired["iterm-window-1"].status, "idle")

    def test_claude_thinking_timer_counts_as_meaningful_body_change(self) -> None:
        detector = Detector()
        first = detector.resolve([
            make_poll_entry(
                tty_active=True,
                session_name="✳ Claude Code",
                presentation_name="✳ Claude Code",
                command_line="claude --dangerously-skip-permissions",
                non_empty_lines_from_bottom=claude_thinking_window("✻ Considering… (5m18s · thinking with max effort)"),
            )
        ])
        second = detector.resolve([
            make_poll_entry(
                tty_active=True,
                session_name="✳ Claude Code",
                presentation_name="✳ Claude Code",
                command_line="claude --dangerously-skip-permissions",
                non_empty_lines_from_bottom=claude_thinking_window("✳ Considering… (5m19s · thinking with max effort)"),
            )
        ])
        self.assertEqual(first["iterm-window-1"].status, "idle")
        self.assertEqual(second["iterm-window-1"].status, "active")
        self.assertEqual(second["iterm-window-1"].reason, "meaningful-body-change")

    def test_stale_claude_thinking_line_does_not_force_active_without_recent_change(self) -> None:
        detector = Detector()
        baseline = make_poll_entry(
            tty_active=True,
            session_name="✳ Claude Code",
            presentation_name="✳ Claude Code",
            command_line="claude --dangerously-skip-permissions",
            non_empty_lines_from_bottom=claude_thinking_window("✻ Considering… (5m18s · thinking with max effort)"),
        )
        detector.resolve([baseline])
        result = detector.resolve([baseline])
        self.assertEqual(result["iterm-window-1"].status, "idle")
        self.assertEqual(result["iterm-window-1"].reason, "steady")

    def test_tty_signal_no_longer_controls_cooldown(self) -> None:
        detector = Detector()
        detector.resolve(
            [make_poll_entry(tty_active=True, non_empty_lines_from_bottom=long_body_baseline())],
            now=detector_time(0),
        )
        active = detector.resolve(
            [make_poll_entry(tty_active=True, non_empty_lines_from_bottom=long_body_changed_once())],
            now=detector_time(1),
        )
        held = detector.resolve(
            [make_poll_entry(tty_active=False, non_empty_lines_from_bottom=long_body_changed_once())],
            now=detector_time(2),
        )
        self.assertEqual(active["iterm-window-1"].status, "active")
        self.assertEqual(held["iterm-window-1"].status, "active")

    def test_visible_active_rule_eventually_expires_if_static(self) -> None:
        detector = Detector()
        first = detector.resolve([
            make_poll_entry(
                tty_active=True,
                session_name='⠧ vibegrid (codex")',
                presentation_name='⠧ vibegrid (codex")',
                command_line='codex" --dangerously-bypass-approvals-and-sandbox',
                non_empty_lines_from_bottom=[
                    "gpt-5.4 xhigh · 94% left · ~/github/vibegrid",
                    "› Summarize recent commits",
                    "• Working (20m 47s • esc to interrupt)",
                ],
            )
        ], now=detector_time(0))
        second = detector.resolve([
            make_poll_entry(
                tty_active=True,
                session_name='⠧ vibegrid (codex")',
                presentation_name='⠧ vibegrid (codex")',
                command_line='codex" --dangerously-bypass-approvals-and-sandbox',
                non_empty_lines_from_bottom=[
                    "gpt-5.4 xhigh · 94% left · ~/github/vibegrid",
                    "› Summarize recent commits",
                    "• Working (20m 47s • esc to interrupt)",
                ],
            )
        ], now=detector_time(8))
        self.assertEqual(first["iterm-window-1"].status, "active")
        self.assertEqual(second["iterm-window-1"].status, "idle")

    def test_claude_spinner_forces_active_via_named_rule(self) -> None:
        detector = Detector()
        result = detector.resolve([
            make_poll_entry(
                tty_active=True,
                session_name="✳ Claude Code",
                presentation_name="✳ Claude Code",
                command_line="claude --dangerously-skip-permissions",
                non_empty_lines_from_bottom=claude_spinner_window("Compacting conversation..."),
            )
        ])
        self.assertEqual(result["iterm-window-1"].status, "active")
        self.assertEqual(result["iterm-window-1"].reason, "rule:compacting-conversation-spinner")

    def test_quillnook_footer_churn_stays_idle(self) -> None:
        detector = Detector()
        first = detector.resolve([
            make_poll_entry(
                tty_active=True,
                session_name="✳ Claude Code",
                presentation_name="✳ Claude Code",
                command_line="claude --dangerously-skip-permissions",
                non_empty_lines_from_bottom=quillnook_buddy_window("current: 2.1.90 · latest: 2.1.90 Quillnook"),
            )
        ])
        second = detector.resolve([
            make_poll_entry(
                tty_active=True,
                session_name="✳ Claude Code",
                presentation_name="✳ Claude Code",
                command_line="claude --dangerously-skip-permissions",
                non_empty_lines_from_bottom=quillnook_buddy_window("current: 2.1.91 · latest: 2.1.91 Quillnook"),
            )
        ])
        self.assertEqual(first["iterm-window-1"].status, "idle")
        self.assertEqual(second["iterm-window-1"].status, "idle")

    def test_tmux_status_line_churn_does_not_trigger_activity(self) -> None:
        detector = Detector()
        first = detector.resolve([
            make_poll_entry(
                tty_active=True,
                session_name="local-3",
                presentation_name="tmux",
                command_line="tmux attach -t local-3",
                non_empty_lines_from_bottom=tmux_window("[local-3] 0:zsh*                               08:20"),
            )
        ])
        second = detector.resolve([
            make_poll_entry(
                tty_active=True,
                session_name="local-3",
                presentation_name="tmux",
                command_line="tmux attach -t local-3",
                non_empty_lines_from_bottom=tmux_window("[local-3] 0:zsh*                               08:21"),
            )
        ])
        self.assertEqual(first["iterm-window-1"].status, "idle")
        self.assertEqual(second["iterm-window-1"].status, "idle")

    def test_missing_window_drops_detector_state(self) -> None:
        detector = Detector()
        detector.resolve([make_poll_entry(tty_active=True, non_empty_lines_from_bottom=long_body_baseline())])
        detector.resolve([make_poll_entry(tty_active=True, non_empty_lines_from_bottom=long_body_changed_once())])
        detector.resolve([])
        returned = detector.resolve([make_poll_entry(tty_active=True, non_empty_lines_from_bottom=long_body_changed_twice())])
        self.assertEqual(returned["iterm-window-1"].status, "idle")
        self.assertEqual(returned["iterm-window-1"].reason, "baseline")

    def test_codex_profile_marks_working_spinner_active(self) -> None:
        detector = Detector()
        result = detector.resolve([
            make_poll_entry(
                tty_active=True,
                session_name='⠧ vibegrid (codex")',
                presentation_name='⠧ vibegrid (codex")',
                command_line='codex" --dangerously-bypass-approvals-and-sandbox',
                non_empty_lines_from_bottom=[
                    "gpt-5.4 xhigh · 94% left · ~/github/vibegrid",
                    "› Summarize recent commits",
                    "• Working (20m 47s • esc to interrupt)",
                ],
            )
        ])
        self.assertEqual(result["iterm-window-1"].status, "active")
        self.assertEqual(result["iterm-window-1"].profile_id, "codex")

    def test_codex_prompt_edit_activates_without_tty_output(self) -> None:
        detector = Detector()
        detector.resolve([
            make_poll_entry(
                tty_active=False,
                session_name='⠧ vibegrid (codex")',
                presentation_name='⠧ vibegrid (codex")',
                command_line='codex" --dangerously-bypass-approvals-and-sandbox',
                non_empty_lines_from_bottom=[
                    "gpt-5.4 xhigh · 94% left · ~/github/vibegrid",
                    "› ",
                ],
            )
        ])
        result = detector.resolve([
            make_poll_entry(
                tty_active=False,
                session_name='⠧ vibegrid (codex")',
                presentation_name='⠧ vibegrid (codex")',
                command_line='codex" --dangerously-bypass-approvals-and-sandbox',
                non_empty_lines_from_bottom=[
                    "gpt-5.4 xhigh · 94% left · ~/github/vibegrid",
                    "› Summarize recent commits",
                ],
            )
        ])
        self.assertEqual(result["iterm-window-1"].status, "active")
        self.assertEqual(result["iterm-window-1"].reason, "input:prompt-edit")

    def test_claude_prompt_edit_activates_without_tty_output(self) -> None:
        detector = Detector()
        detector.resolve([
            make_poll_entry(
                tty_active=False,
                session_name="✳ Claude Code",
                presentation_name="✳ Claude Code",
                command_line="claude --dangerously-skip-permissions",
                non_empty_lines_from_bottom=[
                    "current: 2.1.90 · latest: 2.1.90    Quillnook",
                    "⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt",
                    ".----.",
                    "❯ ",
                ],
            )
        ])
        result = detector.resolve([
            make_poll_entry(
                tty_active=False,
                session_name="✳ Claude Code",
                presentation_name="✳ Claude Code",
                command_line="claude --dangerously-skip-permissions",
                non_empty_lines_from_bottom=[
                    "current: 2.1.90 · latest: 2.1.90    Quillnook",
                    "⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt",
                    ".----.",
                    "❯ explain the cohere mismatch",
                ],
            )
        ])
        self.assertEqual(result["iterm-window-1"].status, "active")
        self.assertEqual(result["iterm-window-1"].reason, "input:prompt-edit")

    def test_quillnook_buddy_prompt_does_not_trigger_prompt_edit_activity(self) -> None:
        detector = Detector()
        detector.resolve([
            make_poll_entry(
                tty_active=False,
                session_name="✳ Claude Code",
                presentation_name="✳ Claude Code",
                command_line="claude --dangerously-skip-permissions",
                non_empty_lines_from_bottom=[
                    "current: 2.1.90 · latest: 2.1.90    Quillnook",
                    "⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt",
                    "(______)",
                    "❯ ( ✦ ✦ )",
                ],
            )
        ])
        result = detector.resolve([
            make_poll_entry(
                tty_active=False,
                session_name="✳ Claude Code",
                presentation_name="✳ Claude Code",
                command_line="claude --dangerously-skip-permissions",
                non_empty_lines_from_bottom=[
                    "current: 2.1.90 · latest: 2.1.90    Quillnook",
                    "⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt",
                    "(______)",
                    "❯ (✦✦)",
                ],
            )
        ])
        self.assertEqual(result["iterm-window-1"].status, "idle")
        self.assertEqual(result["iterm-window-1"].reason, "no-semantic-body")

    def test_quillnook_buddy_eye_animation_with_typed_text_stays_idle(self) -> None:
        detector = Detector()
        detector.resolve([
            make_poll_entry(
                tty_active=False,
                session_name="✳ Claude Code",
                presentation_name="✳ Claude Code",
                command_line="claude --dangerously-skip-permissions",
                non_empty_lines_from_bottom=[
                    "current: 2.1.90 · latest: 2.1.90    Quillnook",
                    "⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt",
                    "(______)",
                    "❯ k;lk;lk; ( - - )",
                ],
            )
        ])
        result = detector.resolve([
            make_poll_entry(
                tty_active=False,
                session_name="✳ Claude Code",
                presentation_name="✳ Claude Code",
                command_line="claude --dangerously-skip-permissions",
                non_empty_lines_from_bottom=[
                    "current: 2.1.90 · latest: 2.1.90    Quillnook",
                    "⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt",
                    "(______)",
                    "❯ k;lk;lk; ( ✦ ✦ )",
                ],
            )
        ])
        self.assertEqual(result["iterm-window-1"].status, "idle")

    def test_tmux_overlay_composes_with_codex_profile(self) -> None:
        detector = Detector()
        result = detector.resolve([
            make_poll_entry(
                tty_active=True,
                session_name='⠧ vibegrid (codex")',
                presentation_name="tmux",
                command_line="tmux attach -t vibegrid codex",
                non_empty_lines_from_bottom=[
                    "[local-3] 0:zsh*                               08:21",
                    "• Working (20m 47s • esc to interrupt)",
                    "› Summarize recent commits",
                ],
            )
        ])
        self.assertEqual(result["iterm-window-1"].profile_id, "codex+tmux")


if __name__ == "__main__":
    unittest.main()
