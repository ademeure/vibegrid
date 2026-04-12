import Foundation
import Testing
@testable import VibeGrid

// Regression tests for the iTerm activity pipeline — the seam where every
// recent bug has lived (mux kill silent-fall-through, vibed overlay flicker,
// indicator hold-period missing, session-name collision, etc.). All tests are
// pure-function unit tests on the static helpers in AppState.

// MARK: - muxKillArgument

@Test func muxKillArgumentConvertsLocalNumeric() {
    #expect(AppState.muxKillArgument(from: "local-10") == "local:10")
    #expect(AppState.muxKillArgument(from: "local-159") == "local:159")
}

@Test func muxKillArgumentConvertsRemoteNumeric() {
    #expect(AppState.muxKillArgument(from: "neb-4") == "neb:4")
    #expect(AppState.muxKillArgument(from: "lambda-17") == "lambda:17")
}

@Test func muxKillArgumentPreservesSuffix() {
    #expect(AppState.muxKillArgument(from: "neb-4-mcp") == "neb:4-mcp")
    #expect(AppState.muxKillArgument(from: "local-10-oldname") == "local:10-oldname")
    #expect(AppState.muxKillArgument(from: "neb-8-train-a1") == "neb:8-train-a1")
}

@Test func muxKillArgumentRejectsNonMatching() {
    // No "machine-number" pattern — pass through unchanged.
    #expect(AppState.muxKillArgument(from: "plain") == "plain")
    #expect(AppState.muxKillArgument(from: "no-numeric-suffix") == "no-numeric-suffix")
    #expect(AppState.muxKillArgument(from: "") == "")
    // Starts with digits — invalid machine name, untouched.
    #expect(AppState.muxKillArgument(from: "123-456") == "123-456")
}

// MARK: - extractRepositoryGroup

@Test func extractRepositoryGroupHandlesBracketPrefix() {
    #expect(AppState.extractRepositoryGroup(
        sessionName: "[vgrid] task name (tmux)",
        badgeText: nil,
        windowTitle: nil,
        iTermWindowName: nil
    ) == "vgrid")
}

@Test func extractRepositoryGroupHandlesAnglePrefix() {
    #expect(AppState.extractRepositoryGroup(
        sessionName: "<cli> task (tmux)",
        badgeText: nil,
        windowTitle: nil,
        iTermWindowName: nil
    ) == "cli")
}

@Test func extractRepositoryGroupSkipsMuxSessionNames() {
    // Bare mux session names shouldn't be mistaken for repos.
    #expect(AppState.extractRepositoryGroup(
        sessionName: "neb-4-mcp",
        badgeText: nil,
        windowTitle: nil,
        iTermWindowName: nil
    ) == nil)
    #expect(AppState.extractRepositoryGroup(
        sessionName: "local-10",
        badgeText: nil,
        windowTitle: nil,
        iTermWindowName: nil
    ) == nil)
}

@Test func extractRepositoryGroupFromPanePath() {
    #expect(AppState.extractRepositoryGroup(
        sessionName: nil,
        badgeText: nil,
        windowTitle: nil,
        iTermWindowName: nil,
        panePath: "~/github/vibegrid"
    ) == "vibegrid")
}

@Test func extractRepositoryGroupFromWorktreePath() {
    let repo = AppState.extractRepositoryGroup(
        sessionName: nil,
        badgeText: nil,
        windowTitle: nil,
        iTermWindowName: nil,
        panePath: "/Users/arun/github/torch-infinity/.claude/worktrees/fork-1"
    )
    #expect(repo == "torch-infinity ⑂")
}

@Test func extractRepositoryGroupFromClaudeSuffix() {
    #expect(AppState.extractRepositoryGroup(
        sessionName: "vibegrid (claude)",
        badgeText: nil,
        windowTitle: nil,
        iTermWindowName: nil
    ) == "vibegrid")
    #expect(AppState.extractRepositoryGroup(
        sessionName: "myproj (codex)",
        badgeText: nil,
        windowTitle: nil,
        iTermWindowName: nil
    ) == "myproj")
}

// MARK: - iTermIndicatorIsActive

@Test func iTermIndicatorIsActiveWhenCurrentlyActive() {
    let now = Date()
    #expect(AppState.iTermIndicatorIsActive(
        currentlyActive: true,
        lastActiveAt: nil,
        now: now,
        holdSeconds: 7
    ) == true)
}

@Test func iTermIndicatorIsActiveWithinHoldPeriod() {
    let now = Date()
    let lastActive = now.addingTimeInterval(-3) // 3s ago, within 7s hold
    #expect(AppState.iTermIndicatorIsActive(
        currentlyActive: false,
        lastActiveAt: lastActive,
        now: now,
        holdSeconds: 7
    ) == true)
}

@Test func iTermIndicatorIsIdleAfterHoldPeriod() {
    let now = Date()
    let lastActive = now.addingTimeInterval(-10) // 10s ago, outside 7s hold
    #expect(AppState.iTermIndicatorIsActive(
        currentlyActive: false,
        lastActiveAt: lastActive,
        now: now,
        holdSeconds: 7
    ) == false)
}

@Test func iTermIndicatorIsIdleWhenNeverActive() {
    #expect(AppState.iTermIndicatorIsActive(
        currentlyActive: false,
        lastActiveAt: nil,
        now: Date(),
        holdSeconds: 7
    ) == false)
}

@Test func iTermIndicatorHoldBoundary() {
    // Exactly at holdSeconds ago → no longer active (< is strict).
    let now = Date()
    let lastActive = now.addingTimeInterval(-7)
    #expect(AppState.iTermIndicatorIsActive(
        currentlyActive: false,
        lastActiveAt: lastActive,
        now: now,
        holdSeconds: 7
    ) == false)
}

// MARK: - overlayVibedSessionActivityCore

private func makeVibedSession(
    tool: String = "claude",
    status: String = "active",
    windowID: String? = nil,
    name: String? = nil,
    updatedAt: Double = 1_000_000,
    activityReason: String = ""
) -> [String: Any] {
    var s: [String: Any] = [
        "tool": tool,
        "status": status,
        "updated_at": updatedAt,
        "activity_reason": activityReason,
    ]
    if let windowID { s["window_id"] = windowID }
    if let name { s["name"] = name }
    return s
}

private func captureLog() -> (log: (String, String) -> Void, messages: () -> [(String, String)]) {
    var buffer: [(String, String)] = []
    let log: (String, String) -> Void = { component, message in
        buffer.append((component, message))
    }
    return (log, { buffer })
}

@Test func vibedOverlayMatchesByWindowID() {
    var cache: [String: String] = ["key1": "idle"]
    var profileCache: [String: String] = ["key1": "default"]
    var lastActiveAt: [String: Date] = [:]
    let runtimeWindowID = ["key1": "pty-ABC"]
    let sessions = [
        "s1": makeVibedSession(status: "active", windowID: "pty-ABC", name: "neb-4")
    ]
    let (log, _) = captureLog()

    AppState.overlayVibedSessionActivityCore(
        sessions: sessions,
        cache: &cache,
        profileCache: &profileCache,
        sessionNameCache: [:],
        runtimeWindowIDByKey: runtimeWindowID,
        lastActiveAt: &lastActiveAt,
        now: Date(),
        log: log
    )

    #expect(cache["key1"] == "active")
    #expect(profileCache["key1"] == "claude-code")
    #expect(lastActiveAt["key1"] != nil)
}

@Test func vibedOverlayMatchesBySessionName() {
    var cache: [String: String] = ["key1": "idle"]
    var profileCache: [String: String] = [:]
    var lastActiveAt: [String: Date] = [:]
    let sessions = [
        "s1": makeVibedSession(status: "active", windowID: nil, name: "neb-4-mcp")
    ]
    let (log, _) = captureLog()

    AppState.overlayVibedSessionActivityCore(
        sessions: sessions,
        cache: &cache,
        profileCache: &profileCache,
        sessionNameCache: ["key1": "neb-4-mcp"],
        runtimeWindowIDByKey: [:],
        lastActiveAt: &lastActiveAt,
        now: Date(),
        log: log
    )

    #expect(cache["key1"] == "active")
}

@Test func vibedOverlayStaleDuplicateWindowIDPicksActive() {
    // Regression test for the flicker bug: two vibed sessions sharing the same
    // window_id (a detached local-159 + an active neb-4-mcp) previously picked
    // a non-deterministic winner per poll. Now active must always win.
    var cache: [String: String] = ["key1": "active"]
    var profileCache: [String: String] = ["key1": "claude-code+tmux"]
    var lastActiveAt: [String: Date] = [:]
    let runtimeWindowID = ["key1": "pty-SHARED"]
    let sessions = [
        "stale":  makeVibedSession(status: "detached", windowID: "pty-SHARED", name: "local-159", updatedAt: 2_000_000),
        "active": makeVibedSession(status: "active",   windowID: "pty-SHARED", name: "neb-4-mcp", updatedAt: 1_000_000),
    ]
    let (log, _) = captureLog()

    AppState.overlayVibedSessionActivityCore(
        sessions: sessions,
        cache: &cache,
        profileCache: &profileCache,
        sessionNameCache: [:],
        runtimeWindowIDByKey: runtimeWindowID,
        lastActiveAt: &lastActiveAt,
        now: Date(),
        log: log
    )

    #expect(cache["key1"] == "active")
}

@Test func vibedOverlayBothIdleBreaksTieOnUpdatedAt() {
    var cache: [String: String] = ["key1": "active"]
    var profileCache: [String: String] = [:]
    var lastActiveAt: [String: Date] = [:]
    let runtimeWindowID = ["key1": "pty-SHARED"]
    let sessions = [
        "older":  makeVibedSession(status: "detached", windowID: "pty-SHARED", name: "local-159", updatedAt: 1_000_000),
        "newer":  makeVibedSession(status: "idle",     windowID: "pty-SHARED", name: "neb-4-mcp", updatedAt: 2_000_000),
    ]
    let (log, _) = captureLog()

    AppState.overlayVibedSessionActivityCore(
        sessions: sessions,
        cache: &cache,
        profileCache: &profileCache,
        sessionNameCache: [:],
        runtimeWindowIDByKey: runtimeWindowID,
        lastActiveAt: &lastActiveAt,
        now: Date(),
        log: log
    )

    // Both reported not-active, so cache downgrades to "idle".
    #expect(cache["key1"] == "idle")
}

@Test func vibedOverlaySessionNameOneToManyMatchAllKeys() {
    // Regression test for the session-name collision finding: two iTerm
    // windows attached to the same tmux session name must both receive the
    // vibed fallback update, not just one.
    var cache: [String: String] = ["key1": "idle", "key2": "idle"]
    var profileCache: [String: String] = [:]
    var lastActiveAt: [String: Date] = [:]
    let sessions = [
        "s": makeVibedSession(status: "active", windowID: nil, name: "shared-session")
    ]
    let (log, _) = captureLog()

    AppState.overlayVibedSessionActivityCore(
        sessions: sessions,
        cache: &cache,
        profileCache: &profileCache,
        sessionNameCache: [
            "key1": "shared-session",
            "key2": "shared-session",
        ],
        runtimeWindowIDByKey: [:],
        lastActiveAt: &lastActiveAt,
        now: Date(),
        log: log
    )

    #expect(cache["key1"] == "active")
    #expect(cache["key2"] == "active")
}

@Test func vibedOverlayIgnoresNonClaudeTools() {
    var cache: [String: String] = ["key1": "idle"]
    var profileCache: [String: String] = [:]
    var lastActiveAt: [String: Date] = [:]
    let runtimeWindowID = ["key1": "pty-X"]
    let sessions = [
        "s": makeVibedSession(tool: "bash", status: "active", windowID: "pty-X", name: "x")
    ]
    let (log, _) = captureLog()

    AppState.overlayVibedSessionActivityCore(
        sessions: sessions,
        cache: &cache,
        profileCache: &profileCache,
        sessionNameCache: [:],
        runtimeWindowIDByKey: runtimeWindowID,
        lastActiveAt: &lastActiveAt,
        now: Date(),
        log: log
    )

    #expect(cache["key1"] == "idle")
    #expect(profileCache["key1"] == nil)
}

@Test func vibedOverlayPreservesTmuxProfileSuffix() {
    // Screen-content detector reports "default+tmux" for remote Claude
    // sessions. The overlay must rewrite the base to "claude-code" while
    // keeping the "+tmux" suffix.
    var cache: [String: String] = ["key1": "idle"]
    var profileCache: [String: String] = ["key1": "default+tmux"]
    var lastActiveAt: [String: Date] = [:]
    let runtimeWindowID = ["key1": "pty-Q"]
    let sessions = [
        "s": makeVibedSession(tool: "claude", status: "active", windowID: "pty-Q", name: "neb-4")
    ]
    let (log, _) = captureLog()

    AppState.overlayVibedSessionActivityCore(
        sessions: sessions,
        cache: &cache,
        profileCache: &profileCache,
        sessionNameCache: [:],
        runtimeWindowIDByKey: runtimeWindowID,
        lastActiveAt: &lastActiveAt,
        now: Date(),
        log: log
    )

    #expect(profileCache["key1"] == "claude-code+tmux")
}

@Test func vibedOverlayDoesNotClobberExistingClaudeProfile() {
    var cache: [String: String] = ["key1": "idle"]
    var profileCache: [String: String] = ["key1": "claude-code"]
    var lastActiveAt: [String: Date] = [:]
    let runtimeWindowID = ["key1": "pty-Q"]
    let sessions = [
        "s": makeVibedSession(tool: "claude", status: "active", windowID: "pty-Q", name: "neb-4")
    ]
    let (log, _) = captureLog()

    AppState.overlayVibedSessionActivityCore(
        sessions: sessions,
        cache: &cache,
        profileCache: &profileCache,
        sessionNameCache: [:],
        runtimeWindowIDByKey: runtimeWindowID,
        lastActiveAt: &lastActiveAt,
        now: Date(),
        log: log
    )

    #expect(profileCache["key1"] == "claude-code")
}

@Test func vibedOverlayNoMatchIsNoOp() {
    var cache: [String: String] = ["key1": "active"]
    var profileCache: [String: String] = ["key1": "default"]
    var lastActiveAt: [String: Date] = [:]
    let sessions = [
        "s": makeVibedSession(tool: "claude", status: "active", windowID: "pty-DIFFERENT", name: "other")
    ]
    let (log, _) = captureLog()

    AppState.overlayVibedSessionActivityCore(
        sessions: sessions,
        cache: &cache,
        profileCache: &profileCache,
        sessionNameCache: [:],
        runtimeWindowIDByKey: ["key1": "pty-ORIGINAL"],
        lastActiveAt: &lastActiveAt,
        now: Date(),
        log: log
    )

    #expect(cache["key1"] == "active")
    #expect(profileCache["key1"] == "default")
}

@Test func vibedOverlayActiveUpdatesLastActiveAt() {
    var cache: [String: String] = ["key1": "idle"]
    var profileCache: [String: String] = [:]
    var lastActiveAt: [String: Date] = [:]
    let runtimeWindowID = ["key1": "pty-A"]
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let sessions = [
        "s": makeVibedSession(tool: "claude", status: "active", windowID: "pty-A", name: "neb-4")
    ]
    let (log, _) = captureLog()

    AppState.overlayVibedSessionActivityCore(
        sessions: sessions,
        cache: &cache,
        profileCache: &profileCache,
        sessionNameCache: [:],
        runtimeWindowIDByKey: runtimeWindowID,
        lastActiveAt: &lastActiveAt,
        now: fixedNow,
        log: log
    )

    #expect(lastActiveAt["key1"] == fixedNow)
}

@Test func vibedOverlayWindowIDWinsOverSessionName() {
    // When window_id resolves, the session-name fallback should not run for
    // that session. Verify by constructing a sessionNameCache that WOULD
    // match the name but whose key is different from the window_id match.
    var cache: [String: String] = ["by_window": "idle", "by_name": "idle"]
    var profileCache: [String: String] = [:]
    var lastActiveAt: [String: Date] = [:]
    let runtimeWindowID = ["by_window": "pty-X"]
    let sessions = [
        "s": makeVibedSession(tool: "claude", status: "active", windowID: "pty-X", name: "shared-name")
    ]
    let (log, _) = captureLog()

    AppState.overlayVibedSessionActivityCore(
        sessions: sessions,
        cache: &cache,
        profileCache: &profileCache,
        sessionNameCache: ["by_name": "shared-name"],
        runtimeWindowIDByKey: runtimeWindowID,
        lastActiveAt: &lastActiveAt,
        now: Date(),
        log: log
    )

    #expect(cache["by_window"] == "active")
    #expect(cache["by_name"] == "idle") // untouched
}
