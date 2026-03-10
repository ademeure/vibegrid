#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

// MARK: - Keyboard shortcut delivery and AppleScript helpers

extension WindowManagerEngine {

    // MARK: - Keyboard shortcut synthesis

    func sendMoveEverythingNewWindowShortcut() -> Bool {
        // Virtual keycode 45 maps to ANSI "N" on macOS keyboards.
        return sendMoveEverythingKeyboardShortcut(
            keyCode: 45,
            flags: .maskCommand
        )
    }

    func sendMoveEverythingKeyboardShortcut(
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) ??
            CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        struct ModifierKey {
            let keyCode: CGKeyCode
            let flag: CGEventFlags
        }
        let modifierKeys: [ModifierKey] = [
            ModifierKey(keyCode: 55, flag: .maskCommand), // Left Command
            ModifierKey(keyCode: 59, flag: .maskControl), // Left Control
            ModifierKey(keyCode: 58, flag: .maskAlternate), // Left Option
            ModifierKey(keyCode: 56, flag: .maskShift) // Left Shift
        ]

        let activeModifiers = modifierKeys.filter { flags.contains($0.flag) }
        var postedFlags: CGEventFlags = []

        for modifier in activeModifiers {
            guard let modifierDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: modifier.keyCode,
                keyDown: true
            ) else {
                return false
            }
            postedFlags.formUnion(modifier.flag)
            modifierDown.flags = postedFlags
            modifierDown.post(tap: .cghidEventTap)
        }

        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ),
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        ) else {
            return false
        }

        keyDown.flags = postedFlags
        keyUp.flags = postedFlags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        for modifier in activeModifiers.reversed() {
            guard let modifierUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: modifier.keyCode,
                keyDown: false
            ) else {
                return false
            }
            postedFlags.remove(modifier.flag)
            modifierUp.flags = postedFlags
            modifierUp.post(tap: .cghidEventTap)
        }

        return true
    }

    func cgEventFlags(for modifiers: [String]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { partial, modifier in
            let normalizedModifier = modifier
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch normalizedModifier {
            case "cmd", "command":
                partial.insert(.maskCommand)
            case "ctrl", "control":
                partial.insert(.maskControl)
            case "alt", "option":
                partial.insert(.maskAlternate)
            case "shift":
                partial.insert(.maskShift)
            default:
                break
            }
        }
    }

    // MARK: - Hotkey passthrough

    func temporarilyUnregisterHotkeysForPassthrough() {
        hotkeyPassthroughRestoreWorkItem?.cancel()
        hotkeyPassthroughRestoreWorkItem = nil

        hotKeyManager.unregisterAll()
        let restoreWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.hotkeysSuspendedForCapture else {
                return
            }
            self.registerEnabledHotkeys()
        }
        hotkeyPassthroughRestoreWorkItem = restoreWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.08,
            execute: restoreWorkItem
        )
    }

    // MARK: - AppleScript helpers

    func runAppleScript(lines: [String]) -> String? {
        guard !lines.isEmpty else {
            return nil
        }
        let osascriptPath = "/usr/bin/osascript"
        guard FileManager.default.isExecutableFile(atPath: osascriptPath) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: osascriptPath)
        process.arguments = lines.flatMap { ["-e", $0] }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("VibeGrid: failed to run AppleScript: %@", error.localizedDescription)
            return nil
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            if !stderr.isEmpty {
                NSLog("VibeGrid: AppleScript failed (%d): %@", process.terminationStatus, stderr)
            }
            return nil
        }

        return stdout
    }

    func appleScriptListLiteral(_ values: [String]) -> String {
        let escapedValues = values.map { "\"\(appleScriptEscapedString($0))\"" }
        return "{\(escapedValues.joined(separator: ", "))}"
    }

    func appleScriptEscapedString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    // MARK: - Application reopen

    func requestMoveEverythingApplicationReopen(_ app: NSRunningApplication) -> Bool {
        guard let appURL = app.bundleURL else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appURL.path]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("VibeGrid: failed to request reopen for %@: %@", appURL.path, error.localizedDescription)
            return false
        }
    }
}

#endif
