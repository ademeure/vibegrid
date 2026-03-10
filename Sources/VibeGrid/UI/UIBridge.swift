#if os(macOS)
import Foundation
import WebKit

final class UIBridge: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private let appState: AppState
    private let moveEverythingWindowRefreshInterval: TimeInterval = 0.6
    private var moveEverythingWindowInventoryCache: Any = UIBridge.emptyMoveEverythingWindowInventoryPayload
    private var moveEverythingWindowInventoryLastRefreshAt: Date?

    init(webView: WKWebView, appState: AppState) {
        self.webView = webView
        self.appState = appState
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "vibeGridBridge" else {
            return
        }

        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            sendNotice(level: "error", message: "Malformed bridge payload")
            return
        }

        switch type {
        case "ready", "requestState":
            pushStateToWeb()

        case "saveConfig":
            guard let payload = body["payload"] else {
                sendNotice(level: "error", message: "No config payload provided")
                return
            }
            let wrappedPayload = payload as? [String: Any]
            let configPayload = wrappedPayload?["config"] ?? payload
            let silent = wrappedPayload?["silent"] as? Bool ?? false
            do {
                let data = try JSONSerialization.data(withJSONObject: configPayload)
                let parsed = try JSONDecoder().decode(AppConfig.self, from: data)
                if appState.save(config: parsed, refreshControlCenter: false) {
                    sendSaveMetadataToWeb()
                    if !silent {
                        sendNotice(level: "success", message: "Configuration saved")
                    }
                } else {
                    sendNotice(level: "error", message: "Failed to save configuration")
                }
            } catch {
                sendNotice(level: "error", message: "Invalid config payload: \(error)")
            }

        case "jsLog":
            if let payload = body["payload"] as? [String: Any] {
                let level = payload["level"] as? String ?? "info"
                let message = payload["message"] as? String ?? ""
                if let details = payload["details"] as? String, !details.isEmpty {
                    NSLog("VibeGrid JS [%@]: %@ | %@", level, message, details)
                } else {
                    NSLog("VibeGrid JS [%@]: %@", level, message)
                }
            } else {
                NSLog("VibeGrid JS [info]: %@", body.description)
            }

        case "previewPlacement":
            guard let payload = body["payload"] else {
                appState.hidePlacementPreview()
                return
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: payload)
                let placement = try JSONDecoder().decode(PlacementStep.self, from: data)
                appState.previewPlacement(placement)
            } catch {
                appState.hidePlacementPreview()
            }

        case "hidePlacementPreview":
            appState.hidePlacementPreview()

        case "reloadConfig":
            appState.refresh()
            sendNotice(level: "info", message: "Reloaded config from disk")

        case "openConfigFile":
            appState.openConfigFile()

        case "openSettings":
            appState.openSettings()

        case "hideControlCenter":
            appState.hideControlCenter()

        case "toggleMoveEverythingMode":
            let result = appState.toggleMoveEverythingMode()
            switch result {
            case .started:
                sendNotice(level: "success", message: "Window List mode started")
            case .stopped:
                sendNotice(level: "info", message: "Window List mode stopped")
            case .failed(let message):
                sendNotice(level: "error", message: message)
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: true)

        case "ensureMoveEverythingMode":
            let wasActive = appState.moveEverythingModeActive()
            let isActive = appState.ensureMoveEverythingMode()
            pushStateToWeb(forceMoveEverythingWindowRefresh: isActive && !wasActive)

        case "moveEverythingCloseWindow":
            let key = (body["payload"] as? [String: Any])?["key"] as? String ?? ""
            guard !key.isEmpty else {
                sendNotice(level: "error", message: "Missing Window List window key")
                return
            }
            if !appState.closeMoveEverythingWindow(withKey: key) {
                sendNotice(level: "error", message: "Unable to close that window")
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: true)

        case "moveEverythingHideWindow":
            let key = (body["payload"] as? [String: Any])?["key"] as? String ?? ""
            guard !key.isEmpty else {
                sendNotice(level: "error", message: "Missing Window List window key")
                return
            }
            if !appState.hideMoveEverythingWindow(withKey: key) {
                sendNotice(level: "error", message: "Unable to hide that window")
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: true)

        case "moveEverythingShowWindow":
            let key = (body["payload"] as? [String: Any])?["key"] as? String ?? ""
            guard !key.isEmpty else {
                sendNotice(level: "error", message: "Missing Window List window key")
                return
            }
            if !appState.showHiddenMoveEverythingWindow(withKey: key) {
                sendNotice(level: "error", message: "Unable to show that window")
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: true)

        case "moveEverythingFocusWindow":
            let payload = (body["payload"] as? [String: Any]) ?? [:]
            let key = payload["key"] as? String ?? ""
            guard !key.isEmpty else {
                sendNotice(level: "error", message: "Missing Window List window key")
                return
            }
            let movePointerToTopMiddle = payload["movePointerToTopMiddle"] as? Bool ?? false
            if !appState.focusMoveEverythingWindow(
                withKey: key,
                movePointerToTopMiddle: movePointerToTopMiddle
            ) {
                sendNotice(level: "error", message: "Unable to focus that window")
            }

        case "moveEverythingCenterWindow":
            let key = (body["payload"] as? [String: Any])?["key"] as? String ?? ""
            guard !key.isEmpty else {
                sendNotice(level: "error", message: "Missing Window List window key")
                return
            }
            if !appState.centerMoveEverythingWindow(withKey: key) {
                sendNotice(level: "error", message: "Unable to center that window")
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: true)

        case "moveEverythingMaximizeWindow":
            let key = (body["payload"] as? [String: Any])?["key"] as? String ?? ""
            guard !key.isEmpty else {
                sendNotice(level: "error", message: "Missing Window List window key")
                return
            }
            if !appState.maximizeMoveEverythingWindow(withKey: key) {
                sendNotice(level: "error", message: "Unable to maximize that window")
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: true)

        case "moveEverythingRetileVisibleWindows":
            if !appState.retileVisibleMoveEverythingWindows() {
                let message = appState.moveEverythingLastDirectActionError() ?? "Unable to retile visible windows"
                sendNotice(level: "error", message: message)
            } else if let message = appState.moveEverythingLastDirectActionError(), !message.isEmpty {
                sendNotice(level: "info", message: message)
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: true)

        case "moveEverythingMiniRetileVisibleWindows":
            if !appState.miniRetileVisibleMoveEverythingWindows() {
                let message = appState.moveEverythingLastDirectActionError() ?? "Unable to mini retile visible windows"
                sendNotice(level: "error", message: message)
            } else if let message = appState.moveEverythingLastDirectActionError(), !message.isEmpty {
                sendNotice(level: "info", message: message)
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: true)

        case "setMoveEverythingAlwaysOnTop":
            let enabled = (body["payload"] as? [String: Any])?["enabled"] as? Bool ?? false
            appState.setMoveEverythingAlwaysOnTop(enabled: enabled)
            pushStateToWeb(forceMoveEverythingWindowRefresh: false)

        case "setMoveEverythingShowOverlays":
            let enabled = (body["payload"] as? [String: Any])?["enabled"] as? Bool ?? true
            appState.setMoveEverythingShowOverlays(enabled: enabled)
            pushStateToWeb(forceMoveEverythingWindowRefresh: false)

        case "setMoveEverythingMoveToBottom":
            let enabled = (body["payload"] as? [String: Any])?["enabled"] as? Bool ?? false
            appState.setMoveEverythingMoveToBottom(enabled: enabled)
            pushStateToWeb(forceMoveEverythingWindowRefresh: false)

        case "setMoveEverythingDontMoveVibeGrid":
            let enabled = (body["payload"] as? [String: Any])?["enabled"] as? Bool ?? false
            appState.setMoveEverythingDontMoveVibeGrid(enabled: enabled)
            pushStateToWeb(forceMoveEverythingWindowRefresh: false)

        case "setMoveEverythingNarrowMode":
            let enabled = (body["payload"] as? [String: Any])?["enabled"] as? Bool ?? false
            appState.setMoveEverythingNarrowMode(enabled: enabled)

        case "moveEverythingHoverWindow":
            let rawKey = (body["payload"] as? [String: Any])?["key"] as? String
            let key = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = appState.setMoveEverythingHoveredWindow(withKey: (key?.isEmpty == true) ? nil : key)

        case "setLaunchAtLogin":
            let enabled = (body["payload"] as? [String: Any])?["enabled"] as? Bool ?? false
            let result = appState.setLaunchAtLogin(enabled: enabled)
            if let errorMessage = result.errorMessage {
                sendNotice(level: "error", message: errorMessage)
            }
            pushStateToWeb()

        case "openLoginItemsSettings":
            appState.openLoginItemsSettings()

        case "revealConfigInFinder":
            appState.revealConfigInFinder()

        case "copyConfigPath":
            appState.copyConfigPathToPasteboard()
            sendNotice(level: "success", message: "Copied config path")

        case "exitApp":
            appState.terminateApp()

        case "beginHotkeyCapture":
            appState.beginHotkeyCapture()

        case "endHotkeyCapture":
            appState.endHotkeyCapture()

        case "requestAccessibility":
            let payload = (body["payload"] as? [String: Any]) ?? [:]
            let prompt = payload["prompt"] as? Bool ?? true
            let resetPermissionState = payload["reset"] as? Bool ?? false
            _ = appState.requestAccessibility(prompt: prompt, resetPermissionState: resetPermissionState)
            send(
                type: "permission",
                payload: ["accessibility": appState.accessibilityGranted()]
            )

        case "requestYaml":
            send(type: "yaml", payload: ["text": appState.configYAML()])

        case "saveAsYaml":
            switch appState.exportConfigAsYAML() {
            case .success(let message):
                sendNotice(level: "success", message: message)
            case .cancelled:
                break
            case .failure(let message):
                sendNotice(level: "error", message: message)
            }

        case "loadFromYaml":
            switch appState.importConfigFromYAML() {
            case .success(let message):
                sendNotice(level: "success", message: message)
            case .cancelled:
                break
            case .failure(let message):
                sendNotice(level: "error", message: message)
            }

        default:
            sendNotice(level: "error", message: "Unknown action: \(type)")
        }
    }

    func pushStateToWeb(
        forceMoveEverythingWindowRefresh: Bool = false,
        allowMoveEverythingWindowRefresh: Bool = true
    ) {
        guard let configObject = codableToJSONObject(appState.config) else {
            sendNotice(level: "error", message: "Failed to serialize config")
            return
        }
        let issuesObject = codableToJSONObject(appState.hotKeyRegistrationIssues()) ?? []
        let runtime = appState.runtimeEnvironment()
        let launchAtLogin = appState.launchAtLoginState()
        let moveEverythingActive = appState.moveEverythingModeActive()
        let moveEverythingWindowInventoryPayload = resolveMoveEverythingWindowInventoryPayload(
            active: moveEverythingActive,
            forceRefresh: forceMoveEverythingWindowRefresh,
            allowRefresh: allowMoveEverythingWindowRefresh
        )

        let payload: [String: Any] = [
            "config": configObject,
            "hotKeyIssues": issuesObject,
            "configPath": appState.configURLString(),
            "launchAtLogin": [
                "supported": launchAtLogin.supported,
                "enabled": launchAtLogin.enabled,
                "requiresApproval": launchAtLogin.requiresApproval,
                "message": launchAtLogin.message
            ],
            "moveEverythingActive": moveEverythingActive,
            "moveEverythingWindows": moveEverythingWindowInventoryPayload,
            "controlCenterFocused": appState.controlCenterFocused(),
            "moveEverythingControlCenterFocused": appState.moveEverythingControlCenterFocused(),
            "moveEverythingAlwaysOnTop": appState.moveEverythingAlwaysOnTopEnabled(),
            "moveEverythingMoveToBottom": appState.moveEverythingMoveToBottomEnabled(),
            "moveEverythingDontMoveVibeGrid": appState.moveEverythingDontMoveVibeGridEnabled(),
            "moveEverythingShowOverlays": appState.moveEverythingShowOverlaysEnabled(),
            "permissions": [
                "accessibility": appState.accessibilityGranted()
            ],
            "runtime": [
                "sandboxed": runtime.sandboxed,
                "message": runtime.message
            ],
            "yaml": appState.configYAML()
        ]

        send(type: "state", payload: payload)
    }

    private func sendNotice(level: String, message: String) {
        send(type: "notice", payload: [
            "level": level,
            "message": message
        ])
    }

    private func sendSaveMetadataToWeb() {
        let issuesObject = codableToJSONObject(appState.hotKeyRegistrationIssues()) ?? []
        send(type: "saveMeta", payload: [
            "hotKeyIssues": issuesObject,
            "yaml": appState.configYAML()
        ])
    }

    private func send(type: String, payload: Any) {
        guard let webView else { return }

        let envelope: [String: Any] = [
            "type": type,
            "payload": payload
        ]

        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        webView.evaluateJavaScript("window.vibeGridReceive(\(text));", completionHandler: nil)
    }

    private func codableToJSONObject<T: Codable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func resolveMoveEverythingWindowInventoryPayload(
        active: Bool,
        forceRefresh: Bool,
        allowRefresh: Bool
    ) -> Any {
        let now = Date()
        guard active else {
            moveEverythingWindowInventoryCache = UIBridge.emptyMoveEverythingWindowInventoryPayload
            moveEverythingWindowInventoryLastRefreshAt = now
            return moveEverythingWindowInventoryCache
        }

        guard allowRefresh else {
            return moveEverythingWindowInventoryCache
        }

        let shouldRefresh = forceRefresh || {
            guard let lastRefresh = moveEverythingWindowInventoryLastRefreshAt else {
                return true
            }
            return now.timeIntervalSince(lastRefresh) >= moveEverythingWindowRefreshInterval
        }()

        guard shouldRefresh else {
            return moveEverythingWindowInventoryCache
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let refreshedPayload = codableToJSONObject(appState.moveEverythingWindowInventory()) ??
            UIBridge.emptyMoveEverythingWindowInventoryPayload
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        if elapsedMs >= 70 {
            NSLog(
                "VibeGrid perf: ui.refreshMoveEverythingWindowInventory force=%@ took %.1fms",
                forceRefresh ? "true" : "false",
                elapsedMs
            )
        }
        moveEverythingWindowInventoryCache = refreshedPayload
        moveEverythingWindowInventoryLastRefreshAt = Date()
        return refreshedPayload
    }

    private static let emptyMoveEverythingWindowInventoryPayload: [String: Any] = [
        "visible": [],
        "hidden": []
    ]
}

#endif
