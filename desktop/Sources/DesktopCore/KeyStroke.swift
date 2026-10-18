import CoreGraphics
import Foundation

/// A `PRESS_KEY` key with its modifiers, parsed from the spec's names.
public struct KeyStroke: Equatable, Sendable, CustomStringConvertible {
    public enum Key: Equatable, Sendable {
        /// A virtual key code (US ANSI layout).
        case code(CGKeyCode)
        /// A character with no key on the US layout; sent as a unicode key event.
        case character(String)
    }

    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }

    public var key: Key
    public var modifiers: Modifiers
    /// The name as the result reports it, for example "cmd+z" or "return".
    public var name: String
    /// True for a single printable character, which is typing; refused while secure input is active.
    public var isCharacter: Bool

    public var description: String { name }

    public var flags: CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    public static let namedKeys: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "escape": 53, "esc": 53, "tab": 48, "space": 49,
        "delete": 51, "backspace": 51, "forwarddelete": 117,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "pageup": 116, "pagedown": 121, "home": 115, "end": 119,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    /// Unshifted characters of the US ANSI layout.
    public static let characterKeys: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50, " ": 49,
    ]

    /// Shifted characters of the US ANSI layout and the unshifted key they live on.
    public static let shiftedCharacters: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "option": .option, "opt": .option, "alt": .option, "⌥": .option,
        "control": .control, "ctrl": .control, "⌃": .control,
    ]

    public init(key: Key, modifiers: Modifiers, name: String, isCharacter: Bool) {
        self.key = key
        self.modifiers = modifiers
        self.name = name
        self.isCharacter = isCharacter
    }

    /// Parses `key` and `modifiers` as the spec names them.
    public static func parse(key rawKey: String, modifiers rawModifiers: [String] = []) throws(DesktopError) -> KeyStroke {
        var modifiers: Modifiers = []
        var modifierNames: [String] = []
        for raw in rawModifiers {
            let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard let modifier = Self.modifierNames[name] else {
                throw .invalid("Unknown modifier \"\(raw)\"; use cmd, shift, option or control.")
            }
            if !modifiers.contains(modifier) {
                modifiers.insert(modifier)
                modifierNames.append(canonicalName(modifier))
            }
        }
        func named(_ base: String) -> String { (modifierNames + [base]).joined(separator: "+") }

        // A single character is taken as written ("A" is shift+a, " " is space).
        if rawKey.count == 1, let character = rawKey.first {
            if let code = characterKeys[character] {
                return KeyStroke(key: .code(code), modifiers: modifiers, name: named(character == " " ? "space" : String(character)),
                                 isCharacter: character != " ")
            }
            let lower = Character(character.lowercased())
            if character.isUppercase, lower != character, let code = characterKeys[lower] {
                var shifted = modifiers
                shifted.insert(.shift)
                return KeyStroke(key: .code(code), modifiers: shifted, name: named(String(character)), isCharacter: true)
            }
            if let base = shiftedCharacters[character], let code = characterKeys[base] {
                var shifted = modifiers
                shifted.insert(.shift)
                return KeyStroke(key: .code(code), modifiers: shifted, name: named(String(character)), isCharacter: true)
            }
            guard !character.isNewline, character.unicodeScalars.allSatisfy({ !$0.properties.isDefaultIgnorableCodePoint }),
                  !(character.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? true) else {
                throw .invalid("Unsupported key \"\(rawKey.debugDescription)\".")
            }
            // Such a character is posted on virtual key 0 (the "a" key), so with a modifier it would act as, say, cmd+a.
            guard modifiers.isEmpty else {
                throw .invalid("\"\(rawKey)\" has no key on the US layout, so it cannot be combined with modifiers.")
            }
            return KeyStroke(key: .character(String(character)), modifiers: modifiers, name: named(String(character)), isCharacter: true)
        }

        let normalized = rawKey.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        let aliases = ["arrowup": "up", "arrowdown": "down", "arrowleft": "left", "arrowright": "right",
                       "pgup": "pageup", "pgdn": "pagedown", "pgdown": "pagedown", "spacebar": "space", "del": "delete"]
        let name = aliases[normalized] ?? normalized
        guard let code = namedKeys[name] else {
            throw .invalid("Unknown key \"\(rawKey)\"; use return, escape, tab, space, delete, up, down, left, right, "
                           + "pageup, pagedown, f1 to f12, or a single character.")
        }
        return KeyStroke(key: .code(code), modifiers: modifiers, name: named(name), isCharacter: false)
    }

    private static func canonicalName(_ modifier: Modifiers) -> String {
        switch modifier {
        case .command: return "cmd"
        case .shift: return "shift"
        case .option: return "option"
        default: return "control"
        }
    }
}
