#if os(macOS)
import Carbon
import Foundation

struct HotKeyRegistrationIssue: Codable {
    enum Kind: String, Codable {
        case unsupportedKey
        case duplicateInConfig
        case reservedBySystem
        case registerFailed
    }

    let shortcutID: String
    let kind: Kind
    let message: String
}

final class HotKeyManager {
    static let shared = HotKeyManager()

    var onShortcutPressed: ((String) -> Void)?
    private(set) var lastRegistrationIssues: [HotKeyRegistrationIssue] = []
    private var isSuspended = false

    private var hotKeyRefs: [String: EventHotKeyRef] = [:]
    private var idToShortcut: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?

    private struct HotKeyCombo: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private init() {
        installHandlerIfNeeded()
    }

    deinit {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    func register(shortcuts: [ShortcutConfig]) {
        installHandlerIfNeeded()
        unregisterAll()
        lastRegistrationIssues.removeAll()
        var seenCombos: [HotKeyCombo: String] = [:]

        for shortcut in shortcuts {
            guard let resolved = KeyCodeMap.resolve(key: shortcut.hotkey.key) else {
                NSLog("VibeGrid: skipping shortcut '%@' due to unsupported key '%@'", shortcut.id, shortcut.hotkey.key)
                lastRegistrationIssues.append(
                    HotKeyRegistrationIssue(
                        shortcutID: shortcut.id,
                        kind: .unsupportedKey,
                        message: "Unsupported key '\(shortcut.hotkey.key)'"
                    )
                )
                continue
            }

            var modifiersList = shortcut.hotkey.modifiers
            modifiersList.append(contentsOf: resolved.implicitModifiers)
            let modifiers = KeyCodeMap.carbonModifiers(for: modifiersList)
            let combo = HotKeyCombo(keyCode: resolved.keyCode, modifiers: modifiers)

            if let existingShortcutID = seenCombos[combo] {
                let message = String(
                    format: "Duplicate of '%@' (%@ + %@)",
                    existingShortcutID,
                    resolved.canonicalKey,
                    modifiersList.joined(separator: "+")
                )
                NSLog("VibeGrid: skipping shortcut '%@' because %@", shortcut.id, message)
                lastRegistrationIssues.append(
                    HotKeyRegistrationIssue(
                        shortcutID: shortcut.id,
                        kind: .duplicateInConfig,
                        message: message
                    )
                )
                continue
            }
            seenCombos[combo] = shortcut.id

            let hotKeyID = EventHotKeyID(signature: KeyCodeMap.signature, id: nextID)
            var hotKeyRef: EventHotKeyRef?

            let status = RegisterEventHotKey(
                resolved.keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            guard status == noErr, let hotKeyRef else {
                if status == eventHotKeyExistsErr {
                    NSLog(
                        "VibeGrid: failed to register shortcut '%@' because key combo is already in use (%d)",
                        shortcut.id,
                        status
                    )
                    lastRegistrationIssues.append(
                        HotKeyRegistrationIssue(
                            shortcutID: shortcut.id,
                            kind: .reservedBySystem,
                            message: "Key combo appears reserved by another app or system shortcut"
                        )
                    )
                } else {
                    NSLog("VibeGrid: failed to register shortcut '%@' (%d)", shortcut.id, status)
                    lastRegistrationIssues.append(
                        HotKeyRegistrationIssue(
                            shortcutID: shortcut.id,
                            kind: .registerFailed,
                            message: "RegisterEventHotKey failed with status \(status)"
                        )
                    )
                }
                continue
            }

            hotKeyRefs[shortcut.id] = hotKeyRef
            idToShortcut[nextID] = shortcut.id
            nextID += 1
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        idToShortcut.removeAll()
        nextID = 1
    }

    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            HotKeyManager.hotKeyHandler,
            1,
            &eventSpec,
            userData,
            &handlerRef
        )

        if installStatus != noErr {
            NSLog("VibeGrid: failed to install global hotkey handler (%d)", installStatus)
        }
    }

    private func handle(eventID: UInt32) {
        guard !isSuspended else {
            return
        }

        guard let shortcutID = idToShortcut[eventID] else {
            return
        }
        onShortcutPressed?(shortcutID)
    }

    private static let hotKeyHandler: EventHandlerUPP = { _, eventRef, userData in
        guard let eventRef, let userData else {
            return noErr
        }

        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        if status == noErr {
            manager.handle(eventID: hotKeyID.id)
        }

        return noErr
    }
}

enum KeyCodeMap {
    static let signature: OSType = 0x56494259 // VIBY

    struct ResolvedKey {
        let keyCode: UInt32
        let canonicalKey: String
        let implicitModifiers: [String]
    }

    private static let baseKeyMap: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
        "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29,
        "rightbracket": 30, "o": 31, "u": 32, "leftbracket": 33,
        "i": 34, "p": 35, "return": 36, "l": 37, "j": 38,
        "quote": 39, "k": 40, "semicolon": 41, "backslash": 42,
        "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47,
        "tab": 48, "space": 49, "grave": 50, "delete": 51,
        "escape": 53, "capslock": 57,
        "f17": 64, "keypaddecimal": 65, "keypadmultiply": 67, "keypadplus": 69,
        "keypadclear": 71, "volumeup": 72, "volumedown": 73, "mute": 74, "keypaddivide": 75,
        "keypadenter": 76, "keypadminus": 78, "f18": 79, "f19": 80, "keypadequals": 81,
        "keypad0": 82, "keypad1": 83, "keypad2": 84, "keypad3": 85,
        "keypad4": 86, "keypad5": 87, "keypad6": 88, "keypad7": 89,
        "f20": 90, "keypad8": 91, "keypad9": 92,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101,
        "f11": 103, "f13": 105, "f16": 106, "f14": 107, "f10": 109,
        "f12": 111, "f15": 113, "help": 114, "home": 115, "pageup": 116,
        "forwarddelete": 117, "f4": 118, "end": 119, "f2": 120, "pagedown": 121,
        "f1": 122, "left": 123, "right": 124, "down": 125, "up": 126
    ]

    private static let literalAliases: [String: String] = [
        "=": "equal", "-": "minus", "[": "leftbracket", "]": "rightbracket",
        "'": "quote", ";": "semicolon", ",": "comma", ".": "period",
        "`": "grave", "\\": "backslash", "/": "slash"
    ]

    private static let shiftedLiteralAliases: [String: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
        "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal", "{": "leftbracket",
        "}": "rightbracket", "|": "backslash", ":": "semicolon", "\"": "quote",
        "<": "comma", ">": "period", "?": "slash", "~": "grave"
    ]

    private static let aliasMap: [String: String] = [
        "esc": "escape",
        "enter": "return",
        "returnkey": "return",
        "backspace": "delete",
        "del": "delete",
        "forwarddel": "forwarddelete",
        "spacebar": "space",
        "pgup": "pageup",
        "pgdn": "pagedown",
        "pgdown": "pagedown",
        "uparrow": "up",
        "downarrow": "down",
        "leftarrow": "left",
        "rightarrow": "right",
        "keypadasterisk": "keypadmultiply",
        "keypadstar": "keypadmultiply",
        "numpadasterisk": "keypadmultiply",
        "numpadstar": "keypadmultiply",
        "numpadplus": "keypadplus",
        "numpadminus": "keypadminus",
        "numpadslash": "keypaddivide",
        "numpaddivide": "keypaddivide",
        "numpadperiod": "keypaddecimal",
        "numpaddot": "keypaddecimal",
        "numpaddecimal": "keypaddecimal",
        "numpadenter": "keypadenter",
        "numpadequal": "keypadequals",
        "numpadequals": "keypadequals",
        "keypadperiod": "keypaddecimal",
        "keypaddot": "keypaddecimal",
        "keypadslash": "keypaddivide",
        "keypadminus": "keypadminus",
        "keypadequal": "keypadequals"
    ]

    private static let shiftedWordAliases: [String: String] = [
        "exclamation": "1",
        "at": "2",
        "hash": "3",
        "dollar": "4",
        "percent": "5",
        "caret": "6",
        "ampersand": "7",
        "asterisk": "8",
        "star": "8",
        "leftparen": "9",
        "rightparen": "0",
        "underscore": "minus",
        "plus": "equal",
        "leftbrace": "leftbracket",
        "rightbrace": "rightbracket",
        "pipe": "backslash",
        "colon": "semicolon",
        "doublequote": "quote",
        "lessthan": "comma",
        "greaterthan": "period",
        "question": "slash",
        "tilde": "grave"
    ]

    static func resolve(key rawKey: String) -> ResolvedKey? {
        let lowered = rawKey.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if let canonical = literalAliases[lowered], let keyCode = baseKeyMap[canonical] {
            return ResolvedKey(keyCode: keyCode, canonicalKey: canonical, implicitModifiers: [])
        }

        if let canonical = shiftedLiteralAliases[lowered], let keyCode = baseKeyMap[canonical] {
            return ResolvedKey(keyCode: keyCode, canonicalKey: canonical, implicitModifiers: ["shift"])
        }

        let collapsed = collapseKeyName(lowered)
        if let canonical = shiftedWordAliases[collapsed], let keyCode = baseKeyMap[canonical] {
            return ResolvedKey(keyCode: keyCode, canonicalKey: canonical, implicitModifiers: ["shift"])
        }

        let canonical = aliasMap[collapsed] ?? collapsed
        if let keyCode = baseKeyMap[canonical] {
            return ResolvedKey(keyCode: keyCode, canonicalKey: canonical, implicitModifiers: [])
        }

        return nil
    }

    static func carbonModifiers(for modifiers: [String]) -> UInt32 {
        modifiers.reduce(0) { partial, modifier in
            let normalized = collapseKeyName(modifier)
            switch normalized {
            case "cmd", "command":
                return partial | UInt32(cmdKey)
            case "alt", "option":
                return partial | UInt32(optionKey)
            case "ctrl", "control":
                return partial | UInt32(controlKey)
            case "shift":
                return partial | UInt32(shiftKey)
            case "fn", "function":
                return partial | UInt32(kEventKeyModifierFnMask)
            default:
                return partial
            }
        }
    }

    private static func collapseKeyName(_ key: String) -> String {
        key.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[\\s_-]+", with: "", options: .regularExpression)
    }
}

#else
import Foundation

struct HotKeyRegistrationIssue: Codable {
    enum Kind: String, Codable {
        case unsupportedKey
        case duplicateInConfig
        case reservedBySystem
        case registerFailed
    }

    let shortcutID: String
    let kind: Kind
    let message: String
}

final class HotKeyManager {
    static let shared = HotKeyManager()
    var onShortcutPressed: ((String) -> Void)?
    private(set) var lastRegistrationIssues: [HotKeyRegistrationIssue] = []
    private init() {}
    func register(shortcuts: [ShortcutConfig]) { lastRegistrationIssues = [] }
    func unregisterAll() {}
    func setSuspended(_ suspended: Bool) {}
}

enum KeyCodeMap {
    struct ResolvedKey {
        let keyCode: UInt32
        let canonicalKey: String
        let implicitModifiers: [String]
    }

    static func resolve(key: String) -> ResolvedKey? { nil }
    static func carbonModifiers(for modifiers: [String]) -> UInt32 { 0 }
}
#endif
