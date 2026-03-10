#if os(macOS)
import Foundation
import Testing
@testable import VibeGrid

// MARK: - Key resolution

@Test func resolveBasicLetterKeys() {
    for letter in "abcdefghijklmnopqrstuvwxyz" {
        let result = KeyCodeMap.resolve(key: String(letter))
        #expect(result != nil, "Failed to resolve key: \(letter)")
        #expect(result!.implicitModifiers.isEmpty)
    }
}

@Test func resolveNumberKeys() {
    for digit in "0123456789" {
        let result = KeyCodeMap.resolve(key: String(digit))
        #expect(result != nil, "Failed to resolve key: \(digit)")
        #expect(result!.implicitModifiers.isEmpty)
    }
}

@Test func resolveFunctionKeys() {
    for n in 1...20 {
        let result = KeyCodeMap.resolve(key: "f\(n)")
        #expect(result != nil, "Failed to resolve key: f\(n)")
        #expect(result!.implicitModifiers.isEmpty)
    }
}

@Test func resolveNavigationKeys() {
    let navKeys = ["left", "right", "up", "down", "home", "end", "pageup", "pagedown"]
    for key in navKeys {
        let result = KeyCodeMap.resolve(key: key)
        #expect(result != nil, "Failed to resolve key: \(key)")
    }
}

@Test func resolveSpecialKeys() {
    let keys = ["return", "tab", "space", "escape", "delete", "forwarddelete"]
    for key in keys {
        let result = KeyCodeMap.resolve(key: key)
        #expect(result != nil, "Failed to resolve key: \(key)")
    }
}

@Test func resolveAliases() {
    #expect(KeyCodeMap.resolve(key: "esc")?.canonicalKey == "escape")
    #expect(KeyCodeMap.resolve(key: "enter")?.canonicalKey == "return")
    #expect(KeyCodeMap.resolve(key: "backspace")?.canonicalKey == "delete")
    #expect(KeyCodeMap.resolve(key: "del")?.canonicalKey == "delete")
    #expect(KeyCodeMap.resolve(key: "spacebar")?.canonicalKey == "space")
    #expect(KeyCodeMap.resolve(key: "pgup")?.canonicalKey == "pageup")
    #expect(KeyCodeMap.resolve(key: "pgdn")?.canonicalKey == "pagedown")
}

@Test func resolveArrowAliases() {
    #expect(KeyCodeMap.resolve(key: "uparrow")?.canonicalKey == "up")
    #expect(KeyCodeMap.resolve(key: "downarrow")?.canonicalKey == "down")
    #expect(KeyCodeMap.resolve(key: "leftarrow")?.canonicalKey == "left")
    #expect(KeyCodeMap.resolve(key: "rightarrow")?.canonicalKey == "right")
}

@Test func resolveLiteralAliases() {
    #expect(KeyCodeMap.resolve(key: "=")?.canonicalKey == "equal")
    #expect(KeyCodeMap.resolve(key: "-")?.canonicalKey == "minus")
    #expect(KeyCodeMap.resolve(key: "[")?.canonicalKey == "leftbracket")
    #expect(KeyCodeMap.resolve(key: "]")?.canonicalKey == "rightbracket")
    #expect(KeyCodeMap.resolve(key: ";")?.canonicalKey == "semicolon")
    #expect(KeyCodeMap.resolve(key: "'")?.canonicalKey == "quote")
    #expect(KeyCodeMap.resolve(key: ",")?.canonicalKey == "comma")
    #expect(KeyCodeMap.resolve(key: ".")?.canonicalKey == "period")
    #expect(KeyCodeMap.resolve(key: "`")?.canonicalKey == "grave")
    #expect(KeyCodeMap.resolve(key: "/")?.canonicalKey == "slash")
}

@Test func resolveShiftedLiterals() {
    let result = KeyCodeMap.resolve(key: "!")
    #expect(result != nil)
    #expect(result!.canonicalKey == "1")
    #expect(result!.implicitModifiers == ["shift"])

    let at = KeyCodeMap.resolve(key: "@")
    #expect(at?.canonicalKey == "2")
    #expect(at?.implicitModifiers == ["shift"])

    let tilde = KeyCodeMap.resolve(key: "~")
    #expect(tilde?.canonicalKey == "grave")
    #expect(tilde?.implicitModifiers == ["shift"])
}

@Test func resolveIsCaseInsensitive() {
    let lower = KeyCodeMap.resolve(key: "left")
    let upper = KeyCodeMap.resolve(key: "LEFT")
    let mixed = KeyCodeMap.resolve(key: "Left")
    #expect(lower?.keyCode == upper?.keyCode)
    #expect(lower?.keyCode == mixed?.keyCode)
}

@Test func resolveUnknownKeyReturnsNil() {
    #expect(KeyCodeMap.resolve(key: "nonexistent") == nil)
    #expect(KeyCodeMap.resolve(key: "") == nil)
    #expect(KeyCodeMap.resolve(key: "xyz123") == nil)
}

@Test func resolveKeypadKeys() {
    for n in 0...9 {
        let result = KeyCodeMap.resolve(key: "keypad\(n)")
        #expect(result != nil, "Failed to resolve keypad\(n)")
    }
    #expect(KeyCodeMap.resolve(key: "keypadplus") != nil)
    #expect(KeyCodeMap.resolve(key: "keypadminus") != nil)
    #expect(KeyCodeMap.resolve(key: "keypadmultiply") != nil)
    #expect(KeyCodeMap.resolve(key: "keypaddivide") != nil)
    #expect(KeyCodeMap.resolve(key: "keypadenter") != nil)
    #expect(KeyCodeMap.resolve(key: "keypaddecimal") != nil)
}

@Test func resolveNumpadAliases() {
    let multiply1 = KeyCodeMap.resolve(key: "keypadasterisk")
    let multiply2 = KeyCodeMap.resolve(key: "keypadmultiply")
    #expect(multiply1?.keyCode == multiply2?.keyCode)

    let numpadPlus = KeyCodeMap.resolve(key: "numpadplus")
    let keypadPlus = KeyCodeMap.resolve(key: "keypadplus")
    #expect(numpadPlus?.keyCode == keypadPlus?.keyCode)
}

// MARK: - Carbon modifier conversion

@Test func carbonModifiersForSingleModifiers() {
    let cmd = KeyCodeMap.carbonModifiers(for: ["cmd"])
    let alt = KeyCodeMap.carbonModifiers(for: ["alt"])
    let ctrl = KeyCodeMap.carbonModifiers(for: ["ctrl"])
    let shift = KeyCodeMap.carbonModifiers(for: ["shift"])

    #expect(cmd != 0)
    #expect(alt != 0)
    #expect(ctrl != 0)
    #expect(shift != 0)

    // All different
    #expect(cmd != alt)
    #expect(cmd != ctrl)
    #expect(cmd != shift)
    #expect(alt != ctrl)
    #expect(alt != shift)
    #expect(ctrl != shift)
}

@Test func carbonModifiersForCombinations() {
    let cmdAlt = KeyCodeMap.carbonModifiers(for: ["cmd", "alt"])
    let cmd = KeyCodeMap.carbonModifiers(for: ["cmd"])
    let alt = KeyCodeMap.carbonModifiers(for: ["alt"])
    #expect(cmdAlt == cmd | alt)
}

@Test func carbonModifiersForAliases() {
    let command = KeyCodeMap.carbonModifiers(for: ["command"])
    let cmd = KeyCodeMap.carbonModifiers(for: ["cmd"])
    #expect(command == cmd)

    let option = KeyCodeMap.carbonModifiers(for: ["option"])
    let alt = KeyCodeMap.carbonModifiers(for: ["alt"])
    #expect(option == alt)

    let control = KeyCodeMap.carbonModifiers(for: ["control"])
    let ctrl = KeyCodeMap.carbonModifiers(for: ["ctrl"])
    #expect(control == ctrl)
}

@Test func carbonModifiersIgnoresUnknown() {
    let withUnknown = KeyCodeMap.carbonModifiers(for: ["cmd", "banana"])
    let withoutUnknown = KeyCodeMap.carbonModifiers(for: ["cmd"])
    #expect(withUnknown == withoutUnknown)
}

@Test func carbonModifiersEmptyReturnsZero() {
    let result = KeyCodeMap.carbonModifiers(for: [])
    #expect(result == 0)
}

#endif
