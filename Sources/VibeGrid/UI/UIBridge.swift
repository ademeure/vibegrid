#if os(macOS)
import Foundation
import WebKit

final class UIBridge: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private let appState: AppState
    private var moveEverythingWindowInventoryCache: Any = UIBridge.emptyMoveEverythingWindowInventoryPayload
    private var moveEverythingRawInventoryCache: MoveEverythingWindowInventory?
    private var moveEverythingRawInventoryJSONCache: Any?
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
        case "ready":
            pushStateToWeb()

        case "requestState":
            let payload = body["payload"] as? [String: Any]
            let forceMoveEverythingWindowRefresh = payload?["forceMoveEverythingWindowRefresh"] as? Bool ?? false
            let allowMoveEverythingWindowRefresh = payload?["allowMoveEverythingWindowRefresh"] as? Bool ?? true
            pushStateToWeb(
                forceMoveEverythingWindowRefresh: forceMoveEverythingWindowRefresh,
                allowMoveEverythingWindowRefresh: allowMoveEverythingWindowRefresh
            )

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
                    WindowListDebugLogger.log("js.\(level)", "\(message) | \(details)")
                } else {
                    NSLog("VibeGrid JS [%@]: %@", level, message)
                    WindowListDebugLogger.log("js.\(level)", message)
                }
            } else {
                NSLog("VibeGrid JS [info]: %@", body.description)
                WindowListDebugLogger.log("js.info", body.description)
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

        case "windowEditorOpened":
            let payload = body["payload"] as? [String: Any]
            let cardWidth = (payload?["cardWidth"] as? NSNumber)?.intValue ?? 540
            let cardHeight = (payload?["cardHeight"] as? NSNumber)?.intValue ?? 400
            appState.handleWindowEditorOpened(cardWidth: cardWidth, cardHeight: cardHeight)

        case "windowEditorClosed":
            appState.handleWindowEditorClosed()

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

        case "moveEverythingHideWindow":
            let key = (body["payload"] as? [String: Any])?["key"] as? String ?? ""
            guard !key.isEmpty else {
                sendNotice(level: "error", message: "Missing Window List window key")
                return
            }
            if !appState.hideMoveEverythingWindow(withKey: key) {
                sendNotice(level: "error", message: "Unable to hide that window")
            }

        case "moveEverythingShowWindow":
            let key = (body["payload"] as? [String: Any])?["key"] as? String ?? ""
            guard !key.isEmpty else {
                sendNotice(level: "error", message: "Missing Window List window key")
                return
            }
            if !appState.showHiddenMoveEverythingWindow(withKey: key) {
                sendNotice(level: "error", message: "Unable to show that window")
            }

        case "moveEverythingShowAllWindows":
            if !appState.showAllHiddenMoveEverythingWindows() {
                sendNotice(level: "error", message: "Unable to show hidden windows")
            }

        case "moveEverythingSavePositions":
            if !appState.saveCurrentMoveEverythingWindowPositions() {
                let message = appState.moveEverythingLastDirectActionError() ?? "Unable to save current window positions"
                sendNotice(level: "error", message: message)
            } else if let message = appState.moveEverythingLastDirectActionError(), !message.isEmpty {
                sendNotice(level: "info", message: message)
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: false, allowMoveEverythingWindowRefresh: false)

        case "moveEverythingRestorePreviousPositions":
            if !appState.restorePreviousMoveEverythingSavedWindowPositions() {
                let message = appState.moveEverythingLastDirectActionError() ?? "Unable to restore previous saved positions"
                sendNotice(level: "error", message: message)
            } else if let message = appState.moveEverythingLastDirectActionError(), !message.isEmpty {
                sendNotice(level: "info", message: message)
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: false, allowMoveEverythingWindowRefresh: false)

        case "moveEverythingRestoreNextPositions":
            if !appState.restoreNextMoveEverythingSavedWindowPositions() {
                let message = appState.moveEverythingLastDirectActionError() ?? "Unable to restore next saved positions"
                sendNotice(level: "error", message: message)
            } else if let message = appState.moveEverythingLastDirectActionError(), !message.isEmpty {
                sendNotice(level: "info", message: message)
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: false, allowMoveEverythingWindowRefresh: false)

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

        case "moveEverythingRenameITermWindow":
            let payload = (body["payload"] as? [String: Any]) ?? [:]
            let key = payload["key"] as? String ?? ""
            guard !key.isEmpty else {
                WindowListDebugLogger.log("rename", "bridge rejected request with missing key")
                sendNotice(level: "error", message: "Missing Window List window key")
                return
            }
            let windowNumber: Int? = {
                if let number = payload["windowNumber"] as? NSNumber {
                    let parsed = number.intValue
                    return parsed >= 0 ? parsed : nil
                }
                if let numberText = payload["windowNumber"] as? String,
                   let parsed = Int(numberText.trimmingCharacters(in: .whitespacesAndNewlines)),
                   parsed >= 0 {
                    return parsed
                }
                return nil
            }()
            let iTermWindowID = (payload["iTermWindowID"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let appName = payload["appName"] as? String ?? ""
            let framePayload = payload["frame"] as? [String: Any]
            let sourceFrame: MoveEverythingWindowFrameSnapshot? = {
                guard let framePayload else {
                    return nil
                }
                let x = (framePayload["x"] as? NSNumber)?.doubleValue
                let y = (framePayload["y"] as? NSNumber)?.doubleValue
                let width = (framePayload["width"] as? NSNumber)?.doubleValue
                let height = (framePayload["height"] as? NSNumber)?.doubleValue
                guard let x, let y, let width, let height else {
                    return nil
                }
                return MoveEverythingWindowFrameSnapshot(x: x, y: y, width: width, height: height)
            }()
            let sourceTitle = payload["sourceTitle"] as? String ?? ""
            let sourceDisplayedTitle = payload["sourceDisplayedTitle"] as? String ?? ""
            let titleProvided = payload["titleProvided"] as? Bool ?? true
            let title = payload["title"] as? String ?? ""
            let badgeTextProvided = payload["badgeTextProvided"] as? Bool ?? true
            let badgeText = payload["badgeText"] as? String ?? ""
            let badgeColorProvided = payload["badgeColorProvided"] as? Bool ?? true
            let badgeColor = payload["badgeColor"] as? String ?? ""
            let badgeOpacity = payload["badgeOpacity"] as? Int ?? 60
            let badgeSize = payload["badgeSize"] as? Int ?? 55
            WindowListDebugLogger.log(
                "rename",
                "bridge received key=\(key) windowNumber=\(windowNumber?.description ?? "nil") " +
                    "iTermWindowID=\(iTermWindowID.isEmpty ? "nil" : iTermWindowID) " +
                    "appName=\(appName) sourceFrame=\(sourceFrame.map { "\($0.x),\($0.y),\($0.width),\($0.height)" } ?? "nil") " +
                    "sourceTitle=\(sourceTitle) sourceDisplayedTitle=\(sourceDisplayedTitle) " +
                    "titleProvided=\(titleProvided) title=\(title) " +
                    "badgeTextProvided=\(badgeTextProvided) badgeText=\(badgeText) " +
                    "badgeColorProvided=\(badgeColorProvided) badgeColor=\(badgeColor)"
            )
            if !appState.renameMoveEverythingITermWindow(
                withKey: key,
                windowNumber: windowNumber,
                iTermWindowID: iTermWindowID,
                sourceFrame: sourceFrame,
                sourceAppName: appName,
                sourceTitle: sourceTitle,
                sourceDisplayedTitle: sourceDisplayedTitle,
                titleProvided: titleProvided,
                title: title,
                badgeTextProvided: badgeTextProvided,
                badgeText: badgeText,
                badgeColorProvided: badgeColorProvided,
                badgeColor: badgeColor,
                badgeOpacity: badgeOpacity,
                badgeSize: badgeSize
            ) {
                let debugLogName = URL(fileURLWithPath: appState.windowListDebugLogPath()).lastPathComponent
                WindowListDebugLogger.log(
                    "rename",
                    "bridge rename failed key=\(key) debugLog=\(debugLogName)"
                )
                sendNotice(
                    level: "error",
                    message: "Unable to rename that iTerm2 window. See \(debugLogName)."
                )
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

        case "moveEverythingITermRetileVisibleWindows":
            if !appState.iTermRetileVisibleMoveEverythingWindows() {
                let message = appState.moveEverythingLastDirectActionError() ?? "Unable to retile iTerm windows"
                sendNotice(level: "error", message: message)
            } else if let message = appState.moveEverythingLastDirectActionError(), !message.isEmpty {
                sendNotice(level: "info", message: message)
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: true)

        case "moveEverythingNonITermRetileVisibleWindows":
            if !appState.nonITermRetileVisibleMoveEverythingWindows() {
                let message = appState.moveEverythingLastDirectActionError() ?? "Unable to retile non-iTerm windows"
                sendNotice(level: "error", message: message)
            } else if let message = appState.moveEverythingLastDirectActionError(), !message.isEmpty {
                sendNotice(level: "info", message: message)
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: true)

        case "moveEverythingHybridRetileVisibleWindows":
            if !appState.hybridRetileVisibleMoveEverythingWindows() {
                let message = appState.moveEverythingLastDirectActionError() ?? "Unable to hybrid retile visible windows"
                sendNotice(level: "error", message: message)
            } else if let message = appState.moveEverythingLastDirectActionError(), !message.isEmpty {
                sendNotice(level: "info", message: message)
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: true)

        case "moveEverythingUndoRetile":
            if !appState.undoLastMoveEverythingRetile() {
                let message = appState.moveEverythingLastDirectActionError() ?? "Unable to undo the last retile"
                sendNotice(level: "error", message: message)
            } else if let message = appState.moveEverythingLastDirectActionError(), !message.isEmpty {
                sendNotice(level: "info", message: message)
            }
            pushStateToWeb(forceMoveEverythingWindowRefresh: true)

        case "saveControlCenterDefaults":
            guard let window = webView?.window else {
                sendNotice(level: "error", message: "No window available")
                return
            }
            let frame = window.frame
            var config = appState.config
            config.settings.controlCenterFrameX = Double(frame.origin.x)
            config.settings.controlCenterFrameY = Double(frame.origin.y)
            config.settings.controlCenterFrameWidth = Double(frame.size.width)
            config.settings.controlCenterFrameHeight = Double(frame.size.height)
            config.settings.moveEverythingStartAlwaysOnTop = appState.moveEverythingAlwaysOnTopEnabled()
            config.settings.moveEverythingStartMoveToBottom = appState.moveEverythingMoveToBottomEnabled()
            config.settings.moveEverythingStartDontMoveVibeGrid = appState.moveEverythingDontMoveVibeGridEnabled()
            if appState.save(config: config, refreshControlCenter: false) {
                sendNotice(level: "success", message: "Defaults saved (position & toggles)")
            } else {
                sendNotice(level: "error", message: "Failed to save defaults")
            }
            pushStateToWeb()

        case "resetControlCenterDefaults":
            var settings = appState.config.settings
            settings.controlCenterFrameX = nil
            settings.controlCenterFrameY = nil
            settings.controlCenterFrameWidth = nil
            settings.controlCenterFrameHeight = nil
            settings.moveEverythingStartAlwaysOnTop = false
            settings.moveEverythingStartMoveToBottom = false
            settings.moveEverythingStartDontMoveVibeGrid = false
            var config = appState.config
            config.settings = settings
            if appState.save(config: config, refreshControlCenter: false) {
                sendNotice(level: "success", message: "Defaults reset")
            } else {
                sendNotice(level: "error", message: "Failed to reset defaults")
            }
            appState.setMoveEverythingAlwaysOnTop(enabled: false)
            appState.setMoveEverythingMoveToBottom(enabled: false)
            appState.setMoveEverythingDontMoveVibeGrid(enabled: false)
            pushStateToWeb()

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

        case "setMoveEverythingPinMode":
            let enabled = (body["payload"] as? [String: Any])?["enabled"] as? Bool ?? false
            appState.setMoveEverythingPinMode(enabled: enabled)

        case "pinMoveEverythingWindow":
            let key = ((body["payload"] as? [String: Any])?["key"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !key.isEmpty {
                appState.pinMoveEverythingWindow(withKey: key)
                pushStateToWeb(forceMoveEverythingWindowRefresh: false)
            }

        case "unpinMoveEverythingWindow":
            let key = ((body["payload"] as? [String: Any])?["key"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !key.isEmpty {
                appState.unpinMoveEverythingWindow(withKey: key)
                pushStateToWeb(forceMoveEverythingWindowRefresh: false)
            }

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
        guard let configObject = appState.configJSONObject() else {
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
            "configParseError": appState.configParseError() as Any,
            "launchAtLogin": [
                "supported": launchAtLogin.supported,
                "enabled": launchAtLogin.enabled,
                "requiresApproval": launchAtLogin.requiresApproval,
                "message": launchAtLogin.message
            ],
            "moveEverythingActive": moveEverythingActive,
            "moveEverythingWindows": moveEverythingWindowInventoryPayload,
            "moveEverythingFocusedWindowKey": appState.moveEverythingFocusedWindowKey() ?? "",
            "controlCenterFocused": appState.controlCenterFocused(),
            "moveEverythingControlCenterFocused": appState.moveEverythingControlCenterFocused(),
            "moveEverythingAlwaysOnTop": appState.moveEverythingAlwaysOnTopEnabled(),
            "moveEverythingMoveToBottom": appState.moveEverythingMoveToBottomEnabled(),
            "moveEverythingDontMoveVibeGrid": appState.moveEverythingDontMoveVibeGridEnabled(),
            "moveEverythingPinnedWindowKeys": Array(appState.moveEverythingPinnedKeys()),
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

    func sendOpenWindowEditor(key: String) {
        send(type: "openWindowEditor", payload: ["key": key])
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
            moveEverythingRawInventoryCache = nil
            moveEverythingRawInventoryJSONCache = nil
            moveEverythingWindowInventoryCache = UIBridge.emptyMoveEverythingWindowInventoryPayload
            moveEverythingWindowInventoryLastRefreshAt = now
            return moveEverythingWindowInventoryCache
        }

        guard allowRefresh else {
            // Even when not refreshing the inventory, re-enrich so activity status updates
            if let rawInventory = moveEverythingRawInventoryCache {
                let baseJSON = moveEverythingRawInventoryJSONCache ?? moveEverythingWindowInventoryCache
                return enrichInventoryWithActivity(baseJSON, inventory: rawInventory)
            }
            return moveEverythingWindowInventoryCache
        }

        let shouldRefresh = forceRefresh || {
            guard let lastRefresh = moveEverythingWindowInventoryLastRefreshAt else {
                return true
            }
            return now.timeIntervalSince(lastRefresh) >= resolvedMoveEverythingWindowRefreshInterval()
        }()

        if shouldRefresh {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let rawInventory = appState.moveEverythingWindowInventory()
            moveEverythingRawInventoryCache = rawInventory
            let encodedJSON = codableToJSONObject(rawInventory) ?? UIBridge.emptyMoveEverythingWindowInventoryPayload
            moveEverythingRawInventoryJSONCache = encodedJSON
            let refreshedPayload = enrichInventoryWithActivity(encodedJSON, inventory: rawInventory)
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

        // Inventory hasn't changed but still re-enrich for fresh activity status.
        // Reuse the cached JSON encoding to avoid redundant Codable → JSON round-trips.
        if let rawInventory = moveEverythingRawInventoryCache {
            let baseJSON = moveEverythingRawInventoryJSONCache ?? moveEverythingWindowInventoryCache
            return enrichInventoryWithActivity(baseJSON, inventory: rawInventory)
        }
        return moveEverythingWindowInventoryCache
    }

    private func resolvedMoveEverythingWindowRefreshInterval() -> TimeInterval {
        let configured = appState.config.settings.moveEverythingBackgroundRefreshInterval
        if configured.isFinite {
            return max(0.2, min(configured, 30))
        }
        return 0.6
    }

    private func enrichInventoryWithActivity(_ payload: Any, inventory: MoveEverythingWindowInventory) -> Any {
        // Kick off an async iTerm screen poll (results arrive and trigger refresh).
        // Pass the inventory we already have to avoid a redundant AX enumeration.
        appState.refreshITermActivity(cachedInventory: inventory)

        // Compute activity status from detector output built from recent
        // visible-screen deltas and profile-specific rules.
        let activityCache = appState.iTermActivityCache
        let badgeTextCache = appState.iTermBadgeTextCache
        let sessionNameCache = appState.iTermSessionNameCache
        let lastLineCache = appState.iTermLastLineCache
        var statusByKey: [String: String] = [:]

        for snapshot in inventory.visible + inventory.hidden {
            let appName = snapshot.appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard appName.contains("iterm") else { continue }

            if let status = activityCache[snapshot.key],
               status == "active" || status == "idle" {
                statusByKey[snapshot.key] = status
            }
        }

        guard var dict = payload as? [String: Any] else { return payload }
        func enrichWindows(_ windows: Any?) -> Any? {
            guard let arr = windows as? [[String: Any]] else { return windows }
            return arr.map { window -> [String: Any] in
                var w = window
                let key = (w["key"] as? String) ?? ""
                if let status = statusByKey[key] {
                    w["iTermActivityStatus"] = status
                }
                if let badge = badgeTextCache[key] {
                    w["iTermBadgeText"] = badge
                }
                if let sessionName = sessionNameCache[key] {
                    w["iTermSessionName"] = sessionName
                    WindowListDebugLogger.log("enrich", "key=\(key) sessionName=\(sessionName)")
                }
                if let lastLine = lastLineCache[key] {
                    w["iTermLastLine"] = lastLine
                }
                return w
            }
        }
        dict["visible"] = enrichWindows(dict["visible"])
        dict["hidden"] = enrichWindows(dict["hidden"])
        return dict
    }

    private static let emptyMoveEverythingWindowInventoryPayload: [String: Any] = [
        "visible": [],
        "hidden": [],
        "undoRetileAvailable": false,
        "savedPositionsPreviousAvailable": false,
        "savedPositionsNextAvailable": false,
    ]
}

#endif
